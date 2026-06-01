#!/usr/bin/env bash
# =============================================================================
# setup.sh — Déploiement complet automatisé : Infra IoT E5
# Capteurs → MQTT (Mosquitto) → Backend C++ → MySQL → Dashboard PHP (Apache2)
# =============================================================================
# Usage : sudo bash setup.sh
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ── Couleurs terminal ─────────────────────────────────────────────────────────
RED='\033[0;31m'  GREEN='\033[0;32m'  YELLOW='\033[1;33m'
BLUE='\033[0;34m' CYAN='\033[0;36m'  BOLD='\033[1m'    NC='\033[0m'

step()  { echo -e "\n${BOLD}${BLUE}▶▶  $* ${NC}"; }
ok()    { echo -e "    ${GREEN}✓${NC}  $*"; }
info()  { echo -e "    ${CYAN}→${NC}  $*"; }
warn()  { echo -e "    ${YELLOW}⚠${NC}  $*"; }
die()   { echo -e "\n${RED}ERREUR FATALE :${NC} $*\n"; exit 1; }

# ── Vérification root ─────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Ce script doit être exécuté en root :\n  sudo bash setup.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Paramètres modifiables ────────────────────────────────────────────────────
MQTT_USER="mqtt"
MQTT_PASS="mqtt_pwd"
DB_USER="capteurs_user"
DB_PASS="capteurs_pass"
DB_NAME="capteurs_db"
MQTT_BROKER="localhost"
MQTT_PORT=1883
BINARY="$SCRIPT_DIR/mqtt_mysql_server"
SERVICE="mqtt_mysql_server"

# IP du serveur (détectée automatiquement, excluant 127.x)
SERVER_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
[[ -z "$SERVER_IP" ]] && SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[[ -z "$SERVER_IP" ]] && SERVER_IP="<IP_DU_SERVEUR>"

# ── Bannière ──────────────────────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}"
cat <<'BANNER'
╔══════════════════════════════════════════════════════════════╗
║       Setup IoT E5 — MQTT → MySQL → Apache2 → PHP           ║
╚══════════════════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"
info "Répertoire projet : $SCRIPT_DIR"

# =============================================================================
step "1/9  Paquets système"
# =============================================================================
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    apache2 mysql-server php libapache2-mod-php php-mysql \
    mosquitto mosquitto-clients \
    g++ make libmosquitto-dev libmysqlclient-dev \
    curl ufw > /dev/null 2>&1
ok "apache2, mysql, php, mosquitto, g++, make, libmosquitto-dev, libmysqlclient-dev installés"

# =============================================================================
step "2/9  MySQL — Base de données et utilisateur"
# =============================================================================
mysql_root() { mysql --batch -u root 2>/dev/null "$@"; }

mysql_root <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
ok "Base '${DB_NAME}' et utilisateur '${DB_USER}' créés"

mysql_root "${DB_NAME}" < "$SCRIPT_DIR/schema.sql"
ok "Schéma appliqué (table releves)"

# =============================================================================
step "3/9  Mosquitto — Broker MQTT"
# =============================================================================
cat > /etc/mosquitto/conf.d/local.conf <<'MOSQ'
listener 1883
allow_anonymous false
password_file /etc/mosquitto/passwd

persistence true
persistence_location /var/lib/mosquitto/

log_dest file /var/log/mosquitto/mosquitto.log
log_type error
log_type warning
log_type notice
log_type information
MOSQ
ok "Config /etc/mosquitto/conf.d/local.conf écrite"

mosquitto_passwd -b -c /etc/mosquitto/passwd "${MQTT_USER}" "${MQTT_PASS}"
chmod 640 /etc/mosquitto/passwd
chown mosquitto:mosquitto /etc/mosquitto/passwd 2>/dev/null || true
ok "Compte MQTT '${MQTT_USER}' créé"

systemctl restart mosquitto
systemctl enable mosquitto > /dev/null 2>&1
ok "Mosquitto démarré et activé"

# =============================================================================
step "4/9  Backend C++ — config.h + compilation"
# =============================================================================
cat > "$SCRIPT_DIR/config.h" <<CONFIG
#pragma once

/* ── Broker MQTT ─────────────────────────────────────────── */
#define MQTT_HOST       "${MQTT_BROKER}"
#define MQTT_PORT       ${MQTT_PORT}
#define MQTT_TOPIC      "capteurs/#"
#define MQTT_CLIENT_ID  "mqtt_mysql_server"
#define MQTT_KEEPALIVE  60
#define MQTT_USER       "${MQTT_USER}"
#define MQTT_PASS       "${MQTT_PASS}"

/* ── Base de données MySQL ───────────────────────────────── */
#define DB_HOST  "localhost"
#define DB_USER  "${DB_USER}"
#define DB_PASS  "${DB_PASS}"
#define DB_NAME  "${DB_NAME}"
CONFIG
ok "config.h généré"

make -C "$SCRIPT_DIR" clean > /dev/null 2>&1 || true
make -C "$SCRIPT_DIR" 2>&1 | sed 's/^/    /'
[[ -x "$BINARY" ]] || die "Compilation échouée — vérifier les erreurs ci-dessus"
ok "Binaire compilé : $BINARY"

# =============================================================================
step "5/9  Systemd — Service $SERVICE"
# =============================================================================
cat > /etc/systemd/system/${SERVICE}.service <<UNIT
[Unit]
Description=MQTT → MySQL Bridge (IoT E5)
After=network.target mysql.service mosquitto.service

[Service]
ExecStart=${BINARY}
WorkingDirectory=${SCRIPT_DIR}
Restart=on-failure
RestartSec=5
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable "${SERVICE}" > /dev/null 2>&1
systemctl restart "${SERVICE}"
ok "Service '${SERVICE}' activé et démarré"

# =============================================================================
step "6/9  Apache2 — VirtualHosts"
# =============================================================================
a2enmod rewrite > /dev/null 2>&1 || true

# ── www.nuc.local ─────────────────────────────────────────────────────────────
mkdir -p /var/www/nuc
cat > /var/www/nuc/index.html <<'HTML'
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <title>NUC — Serveur IoT</title>
    <style>
        body { font-family: Arial, sans-serif; text-align: center; margin-top: 80px;
               background: #f0f4f8; color: #333; }
        h1 { color: #2c3e50; } p { color: #555; margin: 10px 0; }
        a { color: #4472C4; text-decoration: none; font-weight: bold; }
        a:hover { text-decoration: underline; }
    </style>
</head>
<body>
    <h1>Serveur IoT — NUC</h1>
    <p>Infrastructure MQTT → MySQL opérationnelle.</p>
    <p><a href="http://www.dashboard.local">→ Ouvrir le Dashboard de supervision</a></p>
</body>
</html>
HTML

cat > /etc/apache2/sites-available/nuc.local.conf <<'VHOST'
<VirtualHost *:80>
    ServerName www.nuc.local
    DocumentRoot /var/www/nuc
    <Directory /var/www/nuc>
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog ${APACHE_LOG_DIR}/nuc_error.log
</VirtualHost>
VHOST
a2ensite nuc.local.conf > /dev/null 2>&1 || true
ok "VirtualHost www.nuc.local"

# ── www.dashboard.local ───────────────────────────────────────────────────────
mkdir -p /var/www/dashboard
cat > /var/www/dashboard/index.php <<'PHP'
<?php
$dsn = "mysql:host=localhost;dbname=capteurs_db;charset=utf8mb4";
try {
    $pdo = new PDO($dsn, 'capteurs_user', 'capteurs_pass', [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION
    ]);
} catch (PDOException $e) {
    die("Connexion DB échouée : " . htmlspecialchars($e->getMessage()));
}

$stmt = $pdo->query(
    "SELECT capteur_id, temperature, pression, humidite, horodatage
     FROM releves ORDER BY horodatage DESC LIMIT 20"
);
$rows  = $stmt->fetchAll(PDO::FETCH_ASSOC);
$total = $pdo->query("SELECT COUNT(*) FROM releves")->fetchColumn();

$capteurs = $pdo->query(
    "SELECT capteur_id, COUNT(*) AS nb, MAX(horodatage) AS dernier
     FROM releves GROUP BY capteur_id"
)->fetchAll(PDO::FETCH_ASSOC);
?>
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <meta http-equiv="refresh" content="10">
    <title>Dashboard Capteurs</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: Arial, sans-serif; background: #f0f4f8; color: #333; padding: 24px; }
        h1 { color: #2c3e50; font-size: 1.6em; margin-bottom: 4px; }
        .meta { color: #888; font-size: 0.85em; margin-bottom: 20px; }
        .cards { display: flex; gap: 14px; margin-bottom: 24px; flex-wrap: wrap; }
        .card { background: #fff; border-radius: 8px; padding: 14px 22px;
                box-shadow: 0 1px 4px rgba(0,0,0,.1); min-width: 140px; }
        .card strong { display: block; font-size: 1.8em; color: #4472C4; }
        .card span { font-size: 0.8em; color: #888; }
        h2 { color: #2c3e50; font-size: 1.1em; margin: 0 0 10px; }
        table { border-collapse: collapse; width: 100%; background: #fff;
                border-radius: 8px; box-shadow: 0 1px 4px rgba(0,0,0,.1);
                overflow: hidden; margin-bottom: 24px; }
        th { background: #4472C4; color: #fff; padding: 10px 14px; text-align: center; font-size: 0.9em; }
        td { border-bottom: 1px solid #eee; padding: 9px 14px; text-align: center; font-size: 0.9em; }
        tr:last-child td { border-bottom: none; }
        tr:nth-child(even) td { background: #f8f9fa; }
        .na { color: #ccc; }
        .sensor { font-weight: bold; color: #2c3e50; text-align: left; }
        .empty { padding: 28px; color: #aaa; }
    </style>
</head>
<body>
    <h1>Supervision Capteurs IoT</h1>
    <p class="meta">Mise à jour : <?= date('d/m/Y H:i:s') ?> — rafraîchissement auto 10 s</p>

    <div class="cards">
        <div class="card"><strong><?= $total ?></strong><span>relevés total</span></div>
        <div class="card"><strong><?= count($capteurs) ?></strong><span>capteurs actifs</span></div>
        <div class="card"><strong><?= count($rows) ?></strong><span>affichés</span></div>
    </div>

    <h2>Capteurs détectés</h2>
    <table style="margin-bottom:24px">
        <thead><tr><th>Capteur</th><th>Relevés</th><th>Dernier message</th></tr></thead>
        <tbody>
        <?php if (empty($capteurs)): ?>
            <tr><td colspan="3" class="empty">Aucun capteur détecté</td></tr>
        <?php else: foreach ($capteurs as $c): ?>
            <tr>
                <td class="sensor"><?= htmlspecialchars($c['capteur_id']) ?></td>
                <td><?= $c['nb'] ?></td>
                <td><?= $c['dernier'] ?></td>
            </tr>
        <?php endforeach; endif; ?>
        </tbody>
    </table>

    <h2>20 derniers relevés</h2>
    <table>
        <thead>
            <tr>
                <th>Capteur</th>
                <th>Température (°C)</th>
                <th>Pression (hPa)</th>
                <th>Humidité (%)</th>
                <th>Horodatage</th>
            </tr>
        </thead>
        <tbody>
        <?php if (empty($rows)): ?>
            <tr><td colspan="5" class="empty">
                Aucun relevé — envoyez un message MQTT de test :<br>
                <code>bash test_message.sh</code>
            </td></tr>
        <?php else: foreach ($rows as $row): ?>
            <tr>
                <td class="sensor"><?= htmlspecialchars($row['capteur_id']) ?></td>
                <td><?= $row['temperature'] > -900
                        ? number_format((float)$row['temperature'], 1)
                        : '<span class="na">—</span>' ?></td>
                <td><?= $row['pression'] > -900
                        ? number_format((float)$row['pression'], 1)
                        : '<span class="na">—</span>' ?></td>
                <td><?= $row['humidite'] > -900
                        ? number_format((float)$row['humidite'], 1)
                        : '<span class="na">—</span>' ?></td>
                <td><?= $row['horodatage'] ?></td>
            </tr>
        <?php endforeach; endif; ?>
        </tbody>
    </table>
</body>
</html>
PHP

chown -R www-data:www-data /var/www/dashboard /var/www/nuc

# VirtualHost par nom : www.dashboard.local
cat > /etc/apache2/sites-available/dashboard.local.conf <<'VHOST'
<VirtualHost *:80>
    ServerName www.dashboard.local
    DocumentRoot /var/www/dashboard
    <Directory /var/www/dashboard>
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog ${APACHE_LOG_DIR}/dashboard_error.log
</VirtualHost>
VHOST
a2ensite dashboard.local.conf > /dev/null 2>&1 || true

# VirtualHost par défaut (accès par IP depuis le LAN) → dashboard
cat > /etc/apache2/sites-available/000-default.conf <<'VHOST'
<VirtualHost *:80>
    DocumentRoot /var/www/dashboard
    <Directory /var/www/dashboard>
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog ${APACHE_LOG_DIR}/default_error.log
</VirtualHost>
VHOST
apache2ctl configtest 2>&1 | grep -v "^$" | sed 's/^/    /' || true
systemctl reload apache2
ok "VirtualHost www.dashboard.local"
ok "Apache2 rechargé"

# =============================================================================
step "7/9  /etc/hosts — DNS local"
# =============================================================================
add_host() {
    grep -qF "$1" /etc/hosts || echo "$1" >> /etc/hosts
}
add_host "127.0.0.1   www.nuc.local"
add_host "127.0.0.1   www.dashboard.local"
ok "/etc/hosts mis à jour"

# =============================================================================
step "8/9  UFW — Pare-feu"
# =============================================================================
if command -v ufw &>/dev/null; then
    ufw allow 22/tcp    comment "SSH"    > /dev/null 2>&1 || true
    ufw allow 80/tcp    comment "HTTP"   > /dev/null 2>&1 || true
    ufw allow 1883/tcp  comment "MQTT"   > /dev/null 2>&1 || true
    ufw deny  3306/tcp  comment "MySQL"  > /dev/null 2>&1 || true
    ufw --force enable  > /dev/null 2>&1 || true
    ok "Règles UFW : 22 ✓ 80 ✓ 1883 ✓ | 3306 ✗"
else
    warn "ufw non disponible — pare-feu ignoré"
fi

# =============================================================================
step "9/9  Vérification bout en bout"
# =============================================================================
ERRORS=0

check_service() {
    local svc="$1"
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        ok "Service $svc : ${GREEN}actif${NC}"
    else
        echo -e "    ${RED}✗${NC}  Service $svc : ${RED}INACTIF${NC}"
        ERRORS=$((ERRORS + 1))
    fi
}

check_service mosquitto
check_service mysql
check_service apache2
check_service "${SERVICE}"

# Test MQTT → MySQL (attendre que le backend soit prêt)
info "Attente démarrage du backend (3 s)..."
sleep 3

info "Envoi message MQTT de test sur capteurs/bmp280..."
if mosquitto_pub \
    -h "${MQTT_BROKER}" -p "${MQTT_PORT}" \
    -u "${MQTT_USER}" -P "${MQTT_PASS}" \
    -t "capteurs/bmp280" \
    -m '{"temperature": 22.5, "pression": 1013.25, "humidite": 58.3}' \
    2>/dev/null; then
    ok "Message MQTT publié"
else
    echo -e "    ${RED}✗${NC}  Publication MQTT échouée"
    ERRORS=$((ERRORS + 1))
fi

sleep 2  # Laisser le backend traiter

ROW_COUNT=$(mysql_root "${DB_NAME}" \
    -e "SELECT COUNT(*) FROM releves WHERE capteur_id='bmp280';" \
    2>/dev/null | tail -1 || echo "0")
if [[ "${ROW_COUNT:-0}" -ge 1 ]]; then
    ok "Donnée en MySQL : test OK (${ROW_COUNT} ligne)"
    mysql_root "${DB_NAME}" -e "TRUNCATE TABLE releves;" 2>/dev/null
    ok "Table releves vidée — prête pour les vrais capteurs"
else
    echo -e "    ${YELLOW}⚠${NC}  Aucune donnée insérée — voir : sudo journalctl -u ${SERVICE} -n 30"
    ERRORS=$((ERRORS + 1))
fi

# Test HTTP
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --resolve "www.dashboard.local:80:127.0.0.1" \
    "http://www.dashboard.local" 2>/dev/null || echo "000")
if [[ "${HTTP_CODE}" == "200" ]]; then
    ok "Dashboard PHP accessible (HTTP ${HTTP_CODE})"
else
    echo -e "    ${YELLOW}⚠${NC}  Dashboard : HTTP ${HTTP_CODE} — voir /var/log/apache2/dashboard_error.log"
    ERRORS=$((ERRORS + 1))
fi

HTTP_NUC=$(curl -s -o /dev/null -w "%{http_code}" \
    --resolve "www.nuc.local:80:127.0.0.1" \
    "http://www.nuc.local" 2>/dev/null || echo "000")
if [[ "${HTTP_NUC}" == "200" ]]; then
    ok "Site statique accessible (HTTP ${HTTP_NUC})"
else
    echo -e "    ${YELLOW}⚠${NC}  Site nuc.local : HTTP ${HTTP_NUC}"
    ERRORS=$((ERRORS + 1))
fi

# =============================================================================
echo -e "\n${BOLD}${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  RÉSUMÉ — CÔTÉ SERVEUR${NC}"
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════${NC}\n"

echo -e "  ${BOLD}IP du serveur :${NC}  ${GREEN}${SERVER_IP}${NC}"
echo ""
echo -e "  ${BOLD}Accès web :${NC}"
echo -e "    http://www.nuc.local              (site statique)"
echo -e "    http://www.dashboard.local        (supervision temps réel)"
echo -e "    http://${SERVER_IP}               (accès direct par IP)"
echo ""
echo -e "  ${BOLD}MQTT :${NC}"
echo -e "    Broker  : ${SERVER_IP}:${MQTT_PORT}"
echo -e "    User    : ${MQTT_USER}  /  Pass : ${MQTT_PASS}"
echo -e "    Topic   : capteurs/<nom_capteur>"
echo -e "    Payload : {\"temperature\": 22.5, \"pression\": 1013.25, \"humidite\": 58.3}"
echo ""
echo -e "  ${BOLD}MySQL :${NC}"
echo -e "    Base : ${DB_NAME}  |  User : ${DB_USER}  |  Pass : ${DB_PASS}"
echo ""
echo -e "  ${BOLD}Commandes utiles :${NC}"
echo -e "    sudo journalctl -u ${SERVICE} -f        # logs backend C++"
echo -e "    sudo journalctl -u mosquitto -f         # logs broker MQTT"
echo -e "    bash ${SCRIPT_DIR}/test_message.sh      # message de test"
echo -e "    mysql -u ${DB_USER} -p${DB_PASS} ${DB_NAME} \\"
echo -e "      -e 'SELECT * FROM releves ORDER BY horodatage DESC LIMIT 5;'"
echo ""

if [[ "${ERRORS}" -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}  ✓  Infra déployée et opérationnelle !${NC}"
else
    echo -e "${YELLOW}${BOLD}  ⚠  Déployé avec ${ERRORS} avertissement(s) — consultez les logs ci-dessus.${NC}"
fi

# =============================================================================
echo -e "\n${BOLD}${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${YELLOW}║         📡  INSTRUCTIONS POUR LES COLLÈGUES M5STACK          ║${NC}"
echo -e "${BOLD}${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}  L'infra est prête. Donne ces infos à tes collègues :${NC}"
echo ""
echo -e "  ${BOLD}${CYAN}┌─ À configurer dans le sketch Arduino ──────────────────────┐${NC}"
echo -e "  ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}  ${BOLD}IP du broker MQTT :${NC}  ${GREEN}${SERVER_IP}${NC}  (c'est l'IP de ce serveur)"
echo -e "  ${CYAN}│${NC}  ${BOLD}Port             :${NC}  1883"
echo -e "  ${CYAN}│${NC}  ${BOLD}User MQTT        :${NC}  ${MQTT_USER}"
echo -e "  ${CYAN}│${NC}  ${BOLD}Mot de passe     :${NC}  ${MQTT_PASS}"
echo -e "  ${CYAN}│${NC}  ${BOLD}Topic            :${NC}  capteurs/<nom_unique>"
echo -e "  ${CYAN}│${NC}                       ex: capteurs/bmp280 / capteurs/scd040"
echo -e "  ${CYAN}│${NC}"
echo -e "  ${BOLD}${CYAN}└────────────────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "  ${BOLD}Code Arduino à copier-coller (capteur ENV4 T/H/P) :${NC}"
echo ""
cat <<ARDUINO
  ─────────────────────────────────────────────────────────────────
  #include <M5Core2.h>      // ou <M5Stack.h> selon le modèle
  #include <WiFi.h>
  #include <PubSubClient.h>
  #include "M5_ENV.h"

  const char* WIFI_SSID   = "NOM_DU_WIFI";          // ← à remplir
  const char* WIFI_PASS   = "MOT_DE_PASSE_WIFI";    // ← à remplir
  const char* MQTT_SERVER = "${SERVER_IP}";
  const int   MQTT_PORT   = 1883;
  const char* MQTT_USER   = "${MQTT_USER}";
  const char* MQTT_PASS   = "${MQTT_PASS}";
  const char* MQTT_TOPIC  = "capteurs/monm5";        // ← nom UNIQUE par M5Stack

  SHT3X sht30; QMP6988 qmp6988;
  WiFiClient espClient;
  PubSubClient client(espClient);

  void reconnectMQTT() {
    while (!client.connected()) {
      if (client.connect("m5-unique-id", MQTT_USER, MQTT_PASS))  // ID UNIQUE !
        Serial.println("MQTT OK");
      else delay(2000);
    }
  }

  void setup() {
    M5.begin(); Wire.begin(); qmp6988.init();
    WiFi.begin(WIFI_SSID, WIFI_PASS);
    while (WiFi.status() != WL_CONNECTED) { delay(500); Serial.print("."); }
    Serial.println("\\nWiFi OK : " + WiFi.localIP().toString());
    client.setServer(MQTT_SERVER, MQTT_PORT);
  }

  void loop() {
    if (!client.connected()) reconnectMQTT();
    client.loop();
    float tmp = 0, hum = 0, pres = 0;
    if (sht30.get() == 0) { tmp = sht30.cTemp; hum = sht30.humidity; }
    pres = qmp6988.calcPressure() / 100.0f;
    char payload[128];
    snprintf(payload, sizeof(payload),
      "{\"temperature\":%.1f,\"humidite\":%.1f,\"pression\":%.1f}",
      tmp, hum, pres);
    client.publish(MQTT_TOPIC, payload);
    delay(5000);
  }
  ─────────────────────────────────────────────────────────────────
ARDUINO
echo ""
echo -e "  ${BOLD}Checklist collègues :${NC}"
echo -e "  ${CYAN}[1]${NC} WiFi 2,4 GHz seulement (l'ESP32 ne gère pas le 5 GHz)"
echo -e "  ${CYAN}[2]${NC} Chaque M5Stack doit avoir un client ID UNIQUE"
echo -e "        ex: \"m5-salle1\", \"m5-salle2\" — deux appareils avec le même ID"
echo -e "        se déconnectent mutuellement en boucle"
echo -e "  ${CYAN}[3]${NC} Le topic doit être de la forme  capteurs/<nom>"
echo -e "        ex: capteurs/env4 | capteurs/scd040 | capteurs/radar"
echo -e "  ${CYAN}[4]${NC} Format JSON du payload attendu par le backend :"
echo -e "        {\"temperature\": 22.5, \"pression\": 1013.25, \"humidite\": 58.3}"
echo -e "        Un champ absent = -999.0 (ignoré). Tout absent = ligne ignorée."
echo -e "  ${CYAN}[5]${NC} Si capteur SCD040 (CO2) : le champ s'appelle \"co2\" pas \"pression\""
echo -e "        Préviens-moi pour que j'adapte la table MySQL et le backend !"
echo ""
echo -e "  ${BOLD}Dépannage rapide M5Stack :${NC}"
echo -e "  ${YELLOW}Pas de WiFi    →${NC} Vérifie SSID/mdp, force le 2,4 GHz"
echo -e "  ${YELLOW}MQTT refusé    →${NC} Vérifie l'IP ${SERVER_IP}, user/pass, port 1883"
echo -e "  ${YELLOW}Pas de données →${NC} Ouvre le Serial Monitor, lis les logs :"
echo -e "                   sudo journalctl -u mosquitto -f"
echo -e "                   sudo journalctl -u ${SERVICE} -f"
echo -e "  ${YELLOW}Déconnexion    →${NC} Client ID dupliqué — change-le !"
echo ""
echo -e "  ${BOLD}Vérifier en direct que les messages arrivent :${NC}"
echo -e "  ${CYAN}mosquitto_sub -h ${SERVER_IP} -p 1883 -u ${MQTT_USER} -P ${MQTT_PASS} -t 'capteurs/#' -v${NC}"
echo ""
echo -e "${BOLD}${GREEN}  Infra prête. Bonne épreuve à tous !${NC}"
echo ""
