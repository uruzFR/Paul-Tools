# Cheat Sheet — Épreuve E5 IRON
## Infra : Capteur → M5Stack → MQTT → backend C++ → MySQL

---

## ARCHITECTURE GLOBALE

```
M5Stack (capteur BMP280)
        │  MQTT publish
        ▼
Mosquitto Broker (port 1883)
        │  libmosquitto
        ▼
mqtt_mysql_server (C++17)
        │  libmysqlclient
        ▼
MySQL  capteurs_db.releves
```

**Topic :** `capteurs/<capteur_id>` — ex. `capteurs/bmp280`  
**Payload :** `{"temperature": 22.5, "pression": 1013.25, "humidite": 58.3}`  
**Sentinelle :** champ absent → `-999.0` ; ligne ignorée si les 3 champs absents.

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

# Fichiers de config réseau (Debian/Ubuntu)
/etc/hosts               # résolution locale
/etc/resolv.conf         # DNS
/etc/network/interfaces  # interfaces statiques (legacy)
# Ou avec netplan (Ubuntu 18+) :
sudo nano /etc/netplan/01-network-manager-all.yaml
sudo netplan apply

# Logs système
journalctl -xe           # logs récents
journalctl -u mosquitto  # logs d'un service
tail -f /var/log/syslog
```

---

## 2. LINUX — SYSTEMCTL (services)

```bash
sudo systemctl start   mosquitto
sudo systemctl stop    mosquitto
sudo systemctl restart mosquitto
sudo systemctl reload  mosquitto      # recharge la config sans coupure
sudo systemctl enable  mosquitto      # démarrage automatique au boot
sudo systemctl disable mosquitto
sudo systemctl status  mosquitto      # état + dernières lignes de log

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

## 3. LINUX — PARE-FEU UFW

```bash
sudo ufw status verbose
sudo ufw enable
sudo ufw disable

# Règles courantes
sudo ufw allow 22        # SSH
sudo ufw allow 80        # HTTP
sudo ufw allow 443       # HTTPS
sudo ufw allow 1883      # MQTT
sudo ufw allow 3306      # MySQL (DANGEREUX en prod — limiter à une IP)
sudo ufw allow from 192.168.1.0/24 to any port 3306

sudo ufw deny 3306
sudo ufw delete allow 3306

# Après modification
sudo ufw reload
```

---

## 4. MYSQL — INSTALLATION & CONFIGURATION

```bash
# Installation
sudo apt update && sudo apt install mysql-server

# Sécurisation initiale
sudo mysql_secure_installation

# Connexion root
sudo mysql -u root -p
mysql -u root -p                  # si le compte root a un mot de passe
mysql -u capteurs_user -p capteurs_db
```

### Commandes SQL essentielles

```sql
-- Bases
SHOW DATABASES;
USE capteurs_db;
SHOW TABLES;
DESCRIBE releves;

-- Créer base + user (à faire en root)
CREATE DATABASE IF NOT EXISTS capteurs_db;
CREATE USER 'capteurs_user'@'localhost' IDENTIFIED BY 'capteurs_pass';
GRANT ALL PRIVILEGES ON capteurs_db.* TO 'capteurs_user'@'localhost';
FLUSH PRIVILEGES;

-- Vérifier les données
SELECT * FROM releves ORDER BY horodatage DESC LIMIT 10;
SELECT capteur_id, COUNT(*) FROM releves GROUP BY capteur_id;
SELECT * FROM releves WHERE capteur_id = 'bmp280';

-- Vider la table (garder la structure)
TRUNCATE TABLE releves;

-- Supprimer et recréer depuis le script
DROP DATABASE capteurs_db;
mysql -u root -p < schema.sql
```

### Charger le schéma SQL du projet

```bash
mysql -u root -p < schema.sql
# ou si la base existe déjà :
mysql -u capteurs_user -p capteurs_db < schema.sql
```

### Fichier de config MySQL

```
/etc/mysql/mysql.conf.d/mysqld.cnf
# bind-address = 127.0.0.1  ← décommenter pour n'accepter que localhost
```

```bash
sudo systemctl restart mysql
```

---

## 5. APACHE2 / LAMP — INSTALLATION & CONFIG

```bash
# Installation pile LAMP
sudo apt install apache2 mysql-server php libapache2-mod-php php-mysql

# Modules utiles
sudo a2enmod rewrite          # pour les .htaccess
sudo a2enmod ssl

# Activer / désactiver un site
sudo a2ensite monsite.conf
sudo a2dissite 000-default.conf
sudo systemctl reload apache2

# Tester la config
sudo apache2ctl configtest
```

### Virtual Host type

```apache
# /etc/apache2/sites-available/monsite.conf
<VirtualHost *:80>
    ServerName monsite.local
    DocumentRoot /var/www/monsite
    <Directory /var/www/monsite>
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog ${APACHE_LOG_DIR}/monsite_error.log
    CustomLog ${APACHE_LOG_DIR}/monsite_access.log combined
</VirtualHost>
```

```bash
sudo a2ensite monsite.conf
sudo systemctl reload apache2
```

### PHP — test rapide

```php
<?php phpinfo(); ?>
# Sauvegarder dans /var/www/html/info.php puis ouvrir http://localhost/info.php
```

```bash
# Config PHP
/etc/php/<version>/apache2/php.ini
# Erreurs visibles en dev :
# display_errors = On
# error_reporting = E_ALL
sudo systemctl restart apache2
```

---

## 6. MOSQUITTO — INSTALLATION & CONFIGURATION

```bash
# Installation
sudo apt install mosquitto mosquitto-clients

# Config principale
sudo nano /etc/mosquitto/mosquitto.conf
# ou créer /etc/mosquitto/conf.d/local.conf
```

### Config minimale (avec authentification)

```
# /etc/mosquitto/conf.d/local.conf
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
# Créer le fichier de mots de passe et ajouter un user
sudo mosquitto_passwd -c /etc/mosquitto/passwd mqtt
# (-c crée le fichier — NE PAS utiliser -c si le fichier existe déjà)

# Ajouter un user supplémentaire
sudo mosquitto_passwd /etc/mosquitto/passwd autreuser

# Supprimer un user
sudo mosquitto_passwd -D /etc/mosquitto/passwd mqtt

sudo systemctl restart mosquitto
```

### Clients Mosquitto — commandes utiles

```bash
# S'abonner (écouter tous les capteurs)
mosquitto_sub -h localhost -p 1883 -u mqtt -P mqtt_pwd -t "capteurs/#" -v

# Publier un message de test
mosquitto_pub -h localhost -p 1883 -u mqtt -P mqtt_pwd \
  -t "capteurs/bmp280" \
  -m '{"temperature": 22.5, "pression": 1013.25, "humidite": 58.3}'

# Script de test du projet
bash test_message.sh

# Sans authentification (broker en allow_anonymous true)
mosquitto_sub -h localhost -t "capteurs/#" -v
mosquitto_pub -h localhost -t "capteurs/test" -m '{"temperature": 20.0}'

# Vérifier que le broker tourne
systemctl status mosquitto
netstat -tlnp | grep 1883
```

### Dépannage Mosquitto

```bash
# Logs en temps réel
sudo journalctl -u mosquitto -f
tail -f /var/log/mosquitto/mosquitto.log

# Tester la connexion depuis la machine
mosquitto_pub -h 127.0.0.1 -p 1883 -u mqtt -P mqtt_pwd -t test -m hello

# Erreur "connection refused" → broker pas lancé ou mauvais port
# Erreur "not authorised"   → mauvais user/pass ou allow_anonymous false sans passwd_file
# Erreur "bad username"     → user inexistant dans passwd_file
```

---

## 7. BACKEND C++ — COMPILATION & CONFIG

### Prérequis (Debian/Ubuntu)

```bash
sudo apt install g++ make libmosquitto-dev libmysqlclient-dev
# ou : default-libmysqlclient-dev
```

### Workflow de base

```bash
# 1. Copier et éditer la config
cp config_dist.h config.h
nano config.h               # adapter MQTT_HOST, DB_HOST, DB_USER, DB_PASS...

# 2. Compiler
make                        # produit ./mqtt_mysql_server
make clean                  # supprimer le binaire

# 3. Lancer
./mqtt_mysql_server

# 4. Arrêter proprement
Ctrl+C   # ou : kill -SIGTERM <PID>
```

### Makefile du projet (rappel)

```makefile
CXX      = g++
CXXFLAGS = -Wall -Wextra -std=c++17 -O2
LDFLAGS  = -lmosquitto -lmysqlclient

TARGET = mqtt_mysql_server
SRC    = mqtt_mysql_server.cpp client_bdd.cpp client_mqtt.cpp

all: $(TARGET)
$(TARGET): $(SRC)
	$(CXX) $(CXXFLAGS) -o $@ $(SRC) $(LDFLAGS)
clean:
	rm -f $(TARGET)
```

### config.h — paramètres à ajuster

```cpp
#define MQTT_HOST      "localhost"    // IP du broker si distant
#define MQTT_PORT      1883
#define MQTT_TOPIC     "capteurs/#"
#define MQTT_CLIENT_ID "mqtt_mysql_server"
#define MQTT_KEEPALIVE 60
#define MQTT_USER      "mqtt"         // si authentification activée
#define MQTT_PASS      "mqtt_pwd"

#define DB_HOST  "localhost"
#define DB_USER  "capteurs_user"
#define DB_PASS  "capteurs_pass"
#define DB_NAME  "capteurs_db"
```

> **Attention :** `config.h` est exclu du dépôt (`.gitignore`). Il faut toujours faire `cp config_dist.h config.h` sur une nouvelle machine.

### Erreurs de compilation fréquentes

| Erreur | Cause | Fix |
|--------|-------|-----|
| `mosquitto.h: No such file` | lib non installée | `sudo apt install libmosquitto-dev` |
| `mysql/mysql.h: No such file` | lib non installée | `sudo apt install libmysqlclient-dev` |
| `config.h: No such file` | config manquante | `cp config_dist.h config.h` |
| `undefined reference to mosquitto_*` | `-lmosquitto` absent | vérifier `LDFLAGS` dans Makefile |
| `undefined reference to mysql_*` | `-lmysqlclient` absent | vérifier `LDFLAGS` dans Makefile |

---

## 8. DIAGRAMME DE CLASSE UML — RÉSUMÉ

```
┌─────────────────────────┐      ┌────────────────────────────────┐
│       ClientBDD          │      │          ClientMQTT             │
├─────────────────────────┤      ├────────────────────────────────┤
│ - conn_: MYSQL*          │      │ - mosq_: mosquitto*             │
│ - host_: const char*     │      │ - host_, client_id_: char*      │
│ - user_, pass_, name_    │      │ - port_, keepalive_: int        │
├─────────────────────────┤      │ - topic_, user_, pass_: char*   │
│ + open(): void           │      │ - cb_: MessageCallback          │
│ + ensure_connection(): int│     ├────────────────────────────────┤
│ + insert(...): int       │      │ + open(): void                  │
│ - connect(): int         │      │ + loop(timeout_ms): int         │
└─────────────────────────┘      │ + close(): void                 │
                                  │ - on_connect() [static]         │
                                  │ - on_message() [static]         │
                                  └────────────────────────────────┘
             │                                   │
             └──────────────┬────────────────────┘
                            │ utilise
                 ┌──────────┴─────────┐
                 │  mqtt_mysql_server  │
                 │  (main + callbacks) │
                 └────────────────────┘
```

---

## 9. DÉBOGAGE — CHECKLIST RAPIDE

### Le serveur C++ ne démarre pas

```bash
# Vérifier les services
systemctl status mosquitto
systemctl status mysql

# Vérifier la config
cat config.h

# Compiler avec messages d'erreur
make 2>&1 | less

# Lancer et voir les erreurs
./mqtt_mysql_server
# Message "connexion échouée" → mauvais host/user/pass dans config.h
# Message "impossible de créer le client" → libmosquitto non initialisée
```

### Aucune donnée dans MySQL

```bash
# 1. Vérifier que le serveur tourne et reçoit des messages
./mqtt_mysql_server   # surveiller les lignes [MQTT] et [DB]

# 2. Envoyer un message de test
bash test_message.sh

# 3. Vérifier dans MySQL
mysql -u capteurs_user -p capteurs_db
SELECT * FROM releves ORDER BY horodatage DESC LIMIT 5;

# 4. Vérifier que le topic correspond
# Le topic DOIT commencer par "capteurs/" (voir MQTT_TOPIC = "capteurs/#")
```

### Mosquitto refuse les connexions

```bash
# Vérifier le port
netstat -tlnp | grep 1883

# Vérifier l'auth
cat /etc/mosquitto/passwd     # ou /mosquitto/data/passwd si Docker

# Tester directement
mosquitto_pub -h localhost -p 1883 -u mqtt -P mqtt_pwd -t test -m ok
# Si "Connection refused" → Mosquitto n'écoute pas sur 1883
# Si "Not authorised"     → mauvais user/pass
```

### Problème MySQL — accès refusé

```bash
sudo mysql -u root -p
SHOW GRANTS FOR 'capteurs_user'@'localhost';
# Si vide :
GRANT ALL PRIVILEGES ON capteurs_db.* TO 'capteurs_user'@'localhost';
FLUSH PRIVILEGES;
```

---

## 10. DOCKER (environnement de test)

```bash
# Depuis le dossier docker/
docker compose up -d          # démarrer MySQL + Mosquitto
docker compose down           # arrêter
docker compose logs -f        # voir les logs
docker compose ps             # état des containers

# Se connecter au MySQL dockerisé
bash docker/shellin_mysql.sh
# ou : docker exec -it <container_id> mysql -u capteurs_user -p capteurs_db
```

Identifiants Docker (voir `docker-compose.yml`) :
- MySQL : user `capteurs_user` / pass `capteurs_pass` / db `capteurs_db`
- MQTT  : user `mqtt` / pass `mqtt_pwd`

---

## 11. PHP — BASES & CONNEXION MYSQL

```php
<?php
// Connexion PDO (recommandé)
$dsn = "mysql:host=localhost;dbname=capteurs_db;charset=utf8mb4";
$pdo = new PDO($dsn, 'capteurs_user', 'capteurs_pass', [
    PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION
]);

// Requête préparée
$stmt = $pdo->prepare("SELECT * FROM releves WHERE capteur_id = ? ORDER BY horodatage DESC LIMIT 10");
$stmt->execute(['bmp280']);
$rows = $stmt->fetchAll(PDO::FETCH_ASSOC);

foreach ($rows as $row) {
    echo $row['horodatage'] . ' — T=' . $row['temperature'] . '°C<br>';
}
?>
```

```php
// Tester la connexion rapidement
<?php
$conn = mysqli_connect("localhost", "capteurs_user", "capteurs_pass", "capteurs_db");
if (!$conn) die("Erreur: " . mysqli_connect_error());
echo "Connexion OK";
?>
```

---

## 12. RÉCAPITULATIF PORTS & SERVICES

| Service | Port | Commande de test |
|---------|------|-----------------|
| SSH | 22 | `ssh user@ip` |
| HTTP (Apache) | 80 | `curl http://localhost` |
| HTTPS | 443 | `curl https://localhost` |
| MySQL | 3306 | `mysql -u root -p` |
| MQTT | 1883 | `mosquitto_pub -h localhost -t test -m ok` |

---

## 13. SÉQUENCE D'INSTALLATION COMPLÈTE (machine neuve)

```bash
sudo apt update && sudo apt upgrade -y

# LAMP
sudo apt install -y apache2 mysql-server php libapache2-mod-php php-mysql

# MQTT
sudo apt install -y mosquitto mosquitto-clients

# Dépendances backend C++
sudo apt install -y g++ make libmosquitto-dev libmysqlclient-dev

# Configurer MySQL
sudo mysql_secure_installation
mysql -u root -p < schema.sql

# Configurer Mosquitto
sudo nano /etc/mosquitto/conf.d/local.conf
sudo mosquitto_passwd -c /etc/mosquitto/passwd mqtt
sudo systemctl restart mosquitto

# Compiler le backend
cp config_dist.h config.h
nano config.h   # adapter les valeurs
make
./mqtt_mysql_server

# Test bout en bout
bash test_message.sh
mysql -u capteurs_user -p capteurs_db -e "SELECT * FROM releves ORDER BY horodatage DESC LIMIT 3;"
```

---

## 14. M5STACK — RAPPELS

- IDE : **Arduino IDE** avec board `M5Stack` installée via gestionnaire de cartes
- Bibliothèques à installer : `M5Stack`, `PubSubClient` (MQTT), bibliothèque capteur BMP280
- Configurer dans le sketch : `WIFI_SSID`, `WIFI_PASS`, `MQTT_SERVER`, `MQTT_PORT`, `MQTT_USER`, `MQTT_PASS`
- Topic de publication : `capteurs/<nom_capteur>`
- Format payload attendu par le backend : `{"temperature": x.x, "pression": x.x, "humidite": x.x}`
- Compiler et uploader : bouton **Upload** (→) dans Arduino IDE
- Port série : `Tools > Port` → sélectionner le port COM/ttyUSB du M5Stack

---

*Dépôt : https://github.com/uruzFR/E5.git*
