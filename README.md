# Cheat Sheet — Épreuve E5 IRON
## Infra IoT : Capteurs → M5Stack → MQTT → Backend C++ → MySQL → Dashboard PHP

---

## ARCHITECTURE COMPLÈTE (identique dans tous les sujets)

```
Capteurs (ENV4 / SCD040 / Radar LD2410 / RFID)
        │ Grove / UART / GPIO
        ▼
ESP32 M5Stack  (WiFi)
        │  MQTT publish   capteurs/<nom>
        ▼
Broker MQTT Mosquitto  (port 1883)
        │  libmosquitto
        ▼
Application Backend C++  (mqtt_mysql_server)
        │  libmysqlclient / SQL
        ▼
MySQL  capteurs_db.releves
        │  PDO PHP
        ▼
Apache2 + PHP
   ├── www.nuc.local       (site statique)
   └── www.dashboard.local (dashboard supervision)
        │  HTTP
        ▼
Navigateur utilisateur
```

**Topics :** `capteurs/<capteur_id>` — ex. `capteurs/bmp280`, `capteurs/scd040`
**Payload :** `{"temperature": 22.5, "pression": 1013.25, "humidite": 58.3}`
**Sentinelle :** champ absent → `-999.0` ; ligne ignorée si les 3 champs absents.
**Capteurs possibles selon le sujet :** ENV4 (T/H/P), SCD040 (T/H/CO2), Radar LD2410 (présence), RFID

---

## 1. LINUX — COMMANDES DE BASE

```bash
# Navigation
ls -la          pwd           cd /chemin
cp src dst      mv src dst    rm -rf dossier
cat fichier     less fichier  grep "motif" fichier
find . -name "*.cpp"

# Permissions
chmod 755 fichier        chown user:groupe fichier
chmod +x script.sh

# Processus
ps aux | grep mosquitto
kill -9 <PID>
top / htop

# Réseau
ip a                     # interfaces réseau
ip route                 # table de routage
ping 192.168.x.x
netstat -tlnp            # ports ouverts
ss -tlnp                 # idem (plus récent)
curl http://localhost/   # tester HTTP

# Logs système
journalctl -xe
journalctl -u mosquitto -f
tail -f /var/log/syslog
tail -f /var/log/apache2/error.log
```

---

## 2. LINUX — CONFIGURATION RÉSEAU (IP STATIQUE)

```bash
# Trouver le nom de l'interface
ip a   # ex. enp3s0 ou eth0

# Ubuntu 18+ : netplan
sudo nano /etc/netplan/01-netcfg.yaml
```

```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    enp3s0:
      dhcp4: no
      addresses:
        - 192.168.1.100/24
      routes:
        - to: default
          via: 192.168.1.1
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
```

```bash
sudo netplan apply

# Vérifier
ip a
ping 8.8.8.8
```

### /etc/hosts — noms DNS locaux (OBLIGATOIRE pour les VirtualHosts)

```bash
sudo nano /etc/hosts
```

```
127.0.0.1   localhost
127.0.0.1   www.nuc.local
127.0.0.1   www.dashboard.local
```

---

## 3. LINUX — SYSTEMCTL (services)

```bash
sudo systemctl start   mosquitto
sudo systemctl stop    mosquitto
sudo systemctl restart mosquitto
sudo systemctl status  mosquitto
sudo systemctl enable  mosquitto      # démarrage auto au boot
sudo systemctl disable mosquitto

# Créer un service systemd pour mqtt_mysql_server
sudo nano /etc/systemd/system/mqtt_mysql_server.service
```

```ini
[Unit]
Description=MQTT MySQL Server
After=network.target mysql.service mosquitto.service

[Service]
ExecStart=/chemin/vers/mqtt_mysql_server
Restart=on-failure
User=www-data

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now mqtt_mysql_server
```

---

## 4. LINUX — PARE-FEU UFW

```bash
sudo ufw status verbose
sudo ufw enable / disable

sudo ufw allow 22        # SSH
sudo ufw allow 80        # HTTP
sudo ufw allow 443       # HTTPS
sudo ufw allow 1883      # MQTT
sudo ufw allow from 192.168.1.0/24 to any port 3306   # MySQL local seulement
sudo ufw deny 3306

sudo ufw delete allow 3306
sudo ufw reload
```

---

## 5. MYSQL — INSTALLATION & CONFIGURATION

```bash
sudo apt update && sudo apt install mysql-server
sudo mysql_secure_installation

# Connexion
sudo mysql -u root -p
mysql -u capteurs_user -p capteurs_db
```

### Commandes SQL essentielles

```sql
SHOW DATABASES;
USE capteurs_db;
SHOW TABLES;
DESCRIBE releves;

-- Créer base + user (en root)
CREATE DATABASE IF NOT EXISTS capteurs_db;
CREATE USER 'capteurs_user'@'localhost' IDENTIFIED BY 'capteurs_pass';
GRANT ALL PRIVILEGES ON capteurs_db.* TO 'capteurs_user'@'localhost';
FLUSH PRIVILEGES;

-- Vérifier droits
SHOW GRANTS FOR 'capteurs_user'@'localhost';

-- Vérifier les données
SELECT * FROM releves ORDER BY horodatage DESC LIMIT 10;
SELECT capteur_id, COUNT(*) FROM releves GROUP BY capteur_id;
SELECT * FROM releves WHERE capteur_id = 'bmp280';
SELECT * FROM releves WHERE horodatage > NOW() - INTERVAL 1 HOUR;

-- Vider la table
TRUNCATE TABLE releves;
```

### Charger le schéma SQL

```bash
mysql -u root -p < schema.sql
# Ou si la base existe :
mysql -u capteurs_user -p capteurs_db < schema.sql
```

### schema.sql du projet

```sql
CREATE DATABASE IF NOT EXISTS capteurs_db;
USE capteurs_db;
CREATE TABLE IF NOT EXISTS releves (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    capteur_id  VARCHAR(64)   NOT NULL,
    temperature FLOAT,
    pression    FLOAT,
    humidite    FLOAT,
    horodatage  TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_capteur (capteur_id),
    INDEX idx_horodatage (horodatage)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

> Si le sujet ajoute CO2 : ajouter `co2 FLOAT` à la table et au backend C++.

---

## 6. APACHE2 / LAMP — INSTALLATION & VIRTUALHOST

```bash
sudo apt install apache2 mysql-server php libapache2-mod-php php-mysql

sudo a2enmod rewrite
sudo apache2ctl configtest    # toujours vérifier avant reload
sudo systemctl reload apache2
```

### VirtualHost site statique — www.nuc.local

```bash
sudo nano /etc/apache2/sites-available/nuc.local.conf
```

```apache
<VirtualHost *:80>
    ServerName www.nuc.local
    DocumentRoot /var/www/nuc
    <Directory /var/www/nuc>
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog ${APACHE_LOG_DIR}/nuc_error.log
</VirtualHost>
```

```bash
sudo mkdir -p /var/www/nuc
echo "<h1>Site NUC</h1>" | sudo tee /var/www/nuc/index.html
sudo a2ensite nuc.local.conf
sudo systemctl reload apache2
```

### VirtualHost dashboard — www.dashboard.local

```bash
sudo nano /etc/apache2/sites-available/dashboard.local.conf
```

```apache
<VirtualHost *:80>
    ServerName www.dashboard.local
    DocumentRoot /var/www/dashboard
    <Directory /var/www/dashboard>
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog ${APACHE_LOG_DIR}/dashboard_error.log
</VirtualHost>
```

```bash
sudo mkdir -p /var/www/dashboard
sudo a2ensite dashboard.local.conf
sudo systemctl reload apache2

# Tester (depuis le serveur ou un client avec /etc/hosts configuré)
curl http://www.nuc.local
curl http://www.dashboard.local
```

> Sur les postes clients, ajouter dans `/etc/hosts` : `<IP_SERVEUR> www.nuc.local www.dashboard.local`

---

## 7. PHP — DASHBOARD DE SUPERVISION

### Page d'affichage des relevés (index.php)

```php
<?php
$dsn = "mysql:host=localhost;dbname=capteurs_db;charset=utf8mb4";
try {
    $pdo = new PDO($dsn, 'capteurs_user', 'capteurs_pass', [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION
    ]);
} catch (PDOException $e) {
    die("Connexion échouée : " . $e->getMessage());
}

$stmt = $pdo->query(
    "SELECT capteur_id, temperature, pression, humidite, horodatage
     FROM releves ORDER BY horodatage DESC LIMIT 20"
);
$rows = $stmt->fetchAll(PDO::FETCH_ASSOC);
?>
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <meta http-equiv="refresh" content="10">  <!-- rafraîchissement auto 10s -->
    <title>Dashboard Capteurs</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: center; }
        th { background-color: #4472C4; color: white; }
        tr:nth-child(even) { background-color: #f2f2f2; }
    </style>
</head>
<body>
    <h1>Supervision Capteurs IoT</h1>
    <p>Dernière mise à jour : <?= date('d/m/Y H:i:s') ?></p>
    <table>
        <tr>
            <th>Capteur</th>
            <th>Température (°C)</th>
            <th>Pression (hPa)</th>
            <th>Humidité (%)</th>
            <th>Horodatage</th>
        </tr>
        <?php foreach ($rows as $row): ?>
        <tr>
            <td><?= htmlspecialchars($row['capteur_id']) ?></td>
            <td><?= $row['temperature'] != -999 ? $row['temperature'] : '—' ?></td>
            <td><?= $row['pression']    != -999 ? $row['pression']    : '—' ?></td>
            <td><?= $row['humidite']    != -999 ? $row['humidite']    : '—' ?></td>
            <td><?= $row['horodatage'] ?></td>
        </tr>
        <?php endforeach; ?>
    </table>
</body>
</html>
```

```bash
sudo cp index.php /var/www/dashboard/
sudo chown www-data:www-data /var/www/dashboard/index.php
# Ouvrir http://www.dashboard.local dans le navigateur
```

### Tester PHP + MySQL en ligne de commande

```bash
php -r "
\$pdo = new PDO('mysql:host=localhost;dbname=capteurs_db', 'capteurs_user', 'capteurs_pass');
echo 'OK';
"
```

---

## 8. MOSQUITTO — INSTALLATION & CONFIGURATION

```bash
sudo apt install mosquitto mosquitto-clients
sudo nano /etc/mosquitto/conf.d/local.conf
```

```
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
```

### Gestion des mots de passe

```bash
# Créer le fichier (1ère fois uniquement)
sudo mosquitto_passwd -c /etc/mosquitto/passwd mqtt
# Ajouter un user
sudo mosquitto_passwd /etc/mosquitto/passwd autreuser
# Supprimer
sudo mosquitto_passwd -D /etc/mosquitto/passwd mqtt

sudo systemctl restart mosquitto
```

### Clients Mosquitto

```bash
# Écouter tous les capteurs
mosquitto_sub -h localhost -p 1883 -u mqtt -P mqtt_pwd -t "capteurs/#" -v

# Publier un message de test
mosquitto_pub -h localhost -p 1883 -u mqtt -P mqtt_pwd \
  -t "capteurs/bmp280" \
  -m '{"temperature": 22.5, "pression": 1013.25, "humidite": 58.3}'

# Script de test du projet
bash test_message.sh

# Logs en temps réel
sudo journalctl -u mosquitto -f
```

### Erreurs Mosquitto fréquentes

| Message | Cause | Fix |
|---------|-------|-----|
| `Connection refused` | broker non démarré | `systemctl start mosquitto` |
| `Not authorised` | mauvais user/pass | vérifier `/etc/mosquitto/passwd` |
| `bad username` | user inexistant | `mosquitto_passwd /etc/mosquitto/passwd <user>` |
| pas de messages reçus | topic différent | vérifier que le M5Stack publie bien sur `capteurs/#` |

---

## 9. BACKEND C++ — COMPILATION & CONFIG

```bash
# Dépendances
sudo apt install g++ make libmosquitto-dev libmysqlclient-dev

# Workflow
cp config_dist.h config.h    # OBLIGATOIRE à chaque nouvelle machine
nano config.h                # adapter les valeurs
make                         # compile mqtt_mysql_server
./mqtt_mysql_server          # lancer
make clean                   # supprimer le binaire
```

### config.h — valeurs à adapter

```cpp
#define MQTT_HOST      "localhost"
#define MQTT_PORT      1883
#define MQTT_TOPIC     "capteurs/#"
#define MQTT_CLIENT_ID "mqtt_mysql_server"
#define MQTT_KEEPALIVE 60
#define MQTT_USER      "mqtt"
#define MQTT_PASS      "mqtt_pwd"

#define DB_HOST  "localhost"
#define DB_USER  "capteurs_user"
#define DB_PASS  "capteurs_pass"
#define DB_NAME  "capteurs_db"
```

### Erreurs de compilation fréquentes

| Erreur | Fix |
|--------|-----|
| `mosquitto.h: No such file` | `sudo apt install libmosquitto-dev` |
| `mysql/mysql.h: No such file` | `sudo apt install libmysqlclient-dev` |
| `config.h: No such file` | `cp config_dist.h config.h` |
| `undefined reference to mosquitto_*` | vérifier `-lmosquitto` dans Makefile |
| `undefined reference to mysql_*` | vérifier `-lmysqlclient` dans Makefile |

### Makefile (rappel)

```makefile
CXX      = g++
CXXFLAGS = -Wall -Wextra -std=c++17 -O2
LDFLAGS  = -lmosquitto -lmysqlclient
TARGET   = mqtt_mysql_server
SRC      = mqtt_mysql_server.cpp client_bdd.cpp client_mqtt.cpp
all: $(TARGET)
$(TARGET): $(SRC)
	$(CXX) $(CXXFLAGS) -o $@ $(SRC) $(LDFLAGS)
clean:
	rm -f $(TARGET)
```

---

## 10. M5STACK / ESP32 — SKETCH ARDUINO

### Installation Arduino IDE

1. Télécharger Arduino IDE
2. `File > Preferences > Additional boards URL` : `https://m5stack.oss-cn-shenzhen.aliyuncs.com/resource/arduino/package_m5stack_index.json`
3. `Tools > Board Manager` → installer **M5Stack**
4. `Tools > Library Manager` → installer : **M5Stack**, **PubSubClient** (MQTT), **Adafruit BMP280** ou **M5Unit-ENV** selon le capteur
5. `Tools > Port` → sélectionner le port COM/ttyUSB du M5Stack
6. `Tools > Board` → **M5Stack-Core2** ou **M5Stack-Core** selon le modèle

### Sketch type — WiFi + MQTT + capteur ENV4 (T/H/P)

```cpp
#include <M5Core2.h>           // ou <M5Stack.h> selon le modèle
#include <WiFi.h>
#include <PubSubClient.h>
#include "M5_ENV.h"            // bibliothèque capteur ENV4

// ── À MODIFIER ──────────────────────────────────
const char* WIFI_SSID   = "NomDuReseau";
const char* WIFI_PASS   = "MotDePasseWifi";
const char* MQTT_SERVER = "192.168.1.100";  // IP du serveur Linux
const int   MQTT_PORT   = 1883;
const char* MQTT_USER   = "mqtt";
const char* MQTT_PASS   = "mqtt_pwd";
const char* MQTT_TOPIC  = "capteurs/env4";
// ────────────────────────────────────────────────

SHT3X sht30;
QMP6988 qmp6988;
WiFiClient espClient;
PubSubClient client(espClient);

void connectWiFi() {
    WiFi.begin(WIFI_SSID, WIFI_PASS);
    M5.Lcd.print("WiFi...");
    while (WiFi.status() != WL_CONNECTED) delay(500);
    M5.Lcd.println(" OK");
}

void connectMQTT() {
    while (!client.connected()) {
        if (client.connect("M5Stack_ENV4", MQTT_USER, MQTT_PASS)) {
            M5.Lcd.println("MQTT OK");
        } else {
            delay(2000);
        }
    }
}

void setup() {
    M5.begin();
    Wire.begin();
    qmp6988.init();
    connectWiFi();
    client.setServer(MQTT_SERVER, MQTT_PORT);
}

void loop() {
    if (!client.connected()) connectMQTT();
    client.loop();

    float tmp = 0, hum = 0, pres = 0;
    if (sht30.get() == 0) { tmp = sht30.cTemp; hum = sht30.humidity; }
    pres = qmp6988.calcPressure() / 100.0f;  // Pa → hPa

    char payload[128];
    snprintf(payload, sizeof(payload),
        "{\"temperature\":%.1f,\"humidite\":%.1f,\"pression\":%.1f}",
        tmp, hum, pres);

    client.publish(MQTT_TOPIC, payload);
    M5.Lcd.printf("T=%.1f H=%.1f P=%.1f\n", tmp, hum, pres);

    delay(5000);  // publier toutes les 5s
}
```

### Sketch type — capteur SCD040 (T/H/CO2)

```cpp
// Remplacer la section capteur par :
#include <SensirionI2CScd4x.h>
SensirionI2CScd4x scd4x;

// Dans setup() :
scd4x.begin(Wire);
scd4x.startPeriodicMeasurement();

// Dans loop() :
uint16_t co2; float tmp, hum;
scd4x.readMeasurement(co2, tmp, hum);
snprintf(payload, sizeof(payload),
    "{\"temperature\":%.1f,\"humidite\":%.1f,\"co2\":%d}",
    tmp, hum, co2);
// Topic : "capteurs/scd040"
```

### Dépannage M5Stack

```
Upload échoue          → vérifier le port COM, maintenir le bouton rouge pendant upload
WiFi ne se connecte pas → vérifier SSID/PASS, le M5Stack doit être sur le même réseau que le serveur
MQTT connexion refusée  → vérifier IP serveur, port 1883 ouvert (ufw), user/pass
Données pas dans MySQL  → vérifier le format JSON du payload, les logs du backend C++
```

---

## 11. DIAGRAMME DE CLASSE UML — RÉSUMÉ

```
┌─────────────────────────┐      ┌────────────────────────────────┐
│       ClientBDD          │      │          ClientMQTT             │
├─────────────────────────┤      ├────────────────────────────────┤
│ - conn_: MYSQL*          │      │ - mosq_: mosquitto*             │
│ - host_, user_           │      │ - host_, client_id_: char*      │
│ - pass_, name_: char*    │      │ - port_, keepalive_: int        │
├─────────────────────────┤      │ - topic_, user_, pass_: char*   │
│ + open(): void           │      │ - cb_: MessageCallback          │
│ + ensure_connection(): int│     ├────────────────────────────────┤
│ + insert(...): int       │      │ + open(): void                  │
│ - connect(): int         │      │ + loop(timeout_ms): int         │
└─────────────────────────┘      │ + close(): void                 │
                                  │ - on_connect() [static]         │
                                  │ - on_message() [static]         │
                                  └────────────────────────────────┘
             │ utilise                          │ utilise
             └──────────────┬───────────────────┘
                            ▼
                 ┌──────────────────────┐
                 │  mqtt_mysql_server    │
                 │  main() + on_message  │
                 │  parse_float_field()  │
                 └──────────────────────┘
```

---

## 12. DÉBOGAGE — CHECKLIST RAPIDE

### Le backend C++ ne démarre pas

```bash
systemctl status mosquitto mysql
cat config.h                        # vérifier les credentials
make 2>&1                           # voir les erreurs de compilation
./mqtt_mysql_server                 # lire le message d'erreur
```

### Aucune donnée dans MySQL

```bash
# 1. Envoyer un message de test
bash test_message.sh

# 2. Observer les logs du backend
./mqtt_mysql_server
# Chercher : [MQTT] topic → payload  et  [DB] Inséré

# 3. Vérifier MySQL
mysql -u capteurs_user -p capteurs_db -e "SELECT * FROM releves ORDER BY horodatage DESC LIMIT 5;"
```

### Dashboard PHP ne s'affiche pas

```bash
# Vérifier Apache
sudo apache2ctl configtest
systemctl status apache2
tail -f /var/log/apache2/dashboard_error.log

# Vérifier que le VirtualHost est activé
ls /etc/apache2/sites-enabled/

# Vérifier /etc/hosts
cat /etc/hosts   # doit contenir www.dashboard.local → 127.0.0.1
```

### MySQL — accès refusé

```bash
sudo mysql -u root -p
SHOW GRANTS FOR 'capteurs_user'@'localhost';
GRANT ALL PRIVILEGES ON capteurs_db.* TO 'capteurs_user'@'localhost';
FLUSH PRIVILEGES;
```

---

## 13. RÉCAPITULATIF PORTS & SERVICES

| Service | Port | Tester |
|---------|------|--------|
| SSH | 22 | `ssh user@ip` |
| HTTP Apache | 80 | `curl http://www.dashboard.local` |
| MySQL | 3306 | `mysql -u capteurs_user -p` |
| MQTT Mosquitto | 1883 | `mosquitto_pub -h localhost -t test -m ok -u mqtt -P mqtt_pwd` |

---

## 14. SÉQUENCE D'INSTALLATION COMPLÈTE (machine neuve)

```bash
sudo apt update && sudo apt upgrade -y

# LAMP + dépendances backend
sudo apt install -y apache2 mysql-server php libapache2-mod-php php-mysql \
                    mosquitto mosquitto-clients \
                    g++ make libmosquitto-dev libmysqlclient-dev

# 1. MySQL
sudo mysql_secure_installation
mysql -u root -p < schema.sql        # créer la base

# 2. Mosquitto
sudo nano /etc/mosquitto/conf.d/local.conf   # coller la config ci-dessus
sudo mosquitto_passwd -c /etc/mosquitto/passwd mqtt
sudo systemctl restart mosquitto

# 3. Apache — deux VirtualHosts
sudo nano /etc/apache2/sites-available/nuc.local.conf
sudo nano /etc/apache2/sites-available/dashboard.local.conf
sudo mkdir -p /var/www/nuc /var/www/dashboard
sudo a2ensite nuc.local.conf dashboard.local.conf
sudo nano /etc/hosts    # ajouter www.nuc.local et www.dashboard.local → 127.0.0.1
sudo systemctl reload apache2

# 4. Dashboard PHP
sudo cp index.php /var/www/dashboard/
sudo chown -R www-data:www-data /var/www/dashboard/

# 5. Backend C++
cp config_dist.h config.h
nano config.h          # adapter les valeurs
make
./mqtt_mysql_server &

# 6. Test bout en bout
bash test_message.sh
curl http://www.dashboard.local
mysql -u capteurs_user -p capteurs_db -e "SELECT * FROM releves ORDER BY horodatage DESC LIMIT 3;"
```

---

## 15. OUTILS DE DEBUG MENTIONNÉS DANS LE SUJET

- **MQTT Explorer** (GUI) : se connecter sur `mqtt://localhost:1883` avec user/pass → voir tous les topics et messages en temps réel
- **dBeaver** (GUI) : connexion MySQL `localhost:3306` avec `capteurs_user` / `capteurs_pass` → inspecter/requêter la base
- **VSCode** : éditer `config.h`, PHP, Arduino

---

*Repo du projet : https://github.com/uruzFR/E5.git*
