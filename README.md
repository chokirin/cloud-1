# Cloud-1 — Déploiement automatisé WordPress sur OVH Cloud

## Architecture

```
Internet
  │
  │  ports 22, 80, 443 uniquement (UFW)
  ▼
Instance OVH (Ubuntu 22.04)
  │
  └── Docker Compose
       ├── nginx (reverse proxy + TLS)
        │     ├── <domaine>.duckdns.org        → WordPress
        │     └── phpmyadmin.<domaine>...   → phpMyAdmin
       ├── wordpress (PHP-FPM)
       ├── mysql (interne uniquement)
       └── phpmyadmin (interne uniquement)
```

**Réseaux Docker :**
- `frontend` : nginx, wordpress, phpmyadmin (trafic web)
- `backend` : wordpress, mysql, phpmyadmin (base de données, isolée d'internet)

---

## Pourquoi cette architecture ?

| Choix | Explication |
|-------|-------------|
| **1 conteneur = 1 processus** | Chaque conteneur a une seule responsabilité (nginx sert, mysql stocke, etc.). Si un service plante, les autres continuent. |
| **nginx en reverse proxy** | C'est la porte d'entrée unique. Tout le trafic passe par lui. Il route vers le bon conteneur selon le sous-domaine. |
| **MySQL dans le réseau backend** | Le port 3306 n'est pas exposé sur l'hôte. Seuls wordpress et phpmyadmin (dans le même réseau Docker) peuvent le contacter. Impossible d'y accéder depuis internet. |
| **TLS (HTTPS)** | Chiffre les données entre le navigateur et le serveur. Let's Encrypt fournit un certificat reconnu gratuitement. |
| **UFW** | Seuls les ports 22 (SSH), 80 (HTTP), 443 (HTTPS) sont ouverts. Tout le reste est bloqué. |
| **Ansible Vault** | Les mots de passe sont chiffrés dans `vault.yml`. Le fichier `.vault_pass` (jamais commité) contient la clé de déchiffrement. |

---

## Fichiers du projet

### `ansible.cfg` — Configuration d'Ansible

```ini
[defaults]
inventory = inventory/hosts.yml   # où trouver la liste des serveurs
host_key_checking = False         # pas de confirmation SSH à chaque fois
retry_files_enabled = False       # pas de fichiers .retry inutiles
interpreter_python = auto_silent  # détecte Python automatiquement
roles_path = roles                # dossier contenant les rôles
```

### `inventory/hosts.yml` — Liste des serveurs

```yaml
all:
  hosts:
    ovh_instance:
      ansible_host: 145.239.52.143            # IP publique OVH
      ansible_user: "ubuntu"                  # utilisateur SSH
      ansible_ssh_private_key_file: "~/.ssh/id_ed25519"  # clé privée
```

Définit **sur quelle machine** Ansible va travailler. `become: yes` dans le playbook donne les droits root sur cette machine.

### `playbook.yml` — Orchestration

```yaml
- name: Deploy Cloud-1 WordPress Infrastructure
  hosts: all          # toutes les machines de l'inventaire
  become: yes         # exécuter en root (sudo)

  roles:
    - docker          # 1. Installer Docker
    - firewall        # 2. Configurer le pare-feu
    - app             # 3. Déployer l'application
```

**Pourquoi cet ordre ?** Docker doit être installé avant de lancer les conteneurs. Le firewall doit être actif avant d'exposer quoi que ce soit.

### `roles/docker/tasks/main.yml` — Installation de Docker

```
1. Installer les prérequis (curl, gnupg...)
2. Ajouter la clé GPG officielle Docker → vérifie l'authenticité des paquets
3. Ajouter le dépôt Docker pour Ubuntu 22.04
4. Installer docker-ce + docker-compose-plugin
5. Démarrer Docker et l'activer au démarrage
6. Ajouter l'utilisateur ubuntu au groupe docker → permet docker sans sudo
7. reset_connection → force une reconnexion SSH pour appliquer le groupe
```

**Pourquoi `reset_connection` ?** Ajouter un utilisateur à un groupe ne prend effet qu'à la prochaine connexion SSH. Sans ça, le rôle `app` ne pourrait pas lancer `docker compose`.

### `roles/firewall/tasks/main.yml` — Pare-feu UFW

```
1. Installer UFW
2. Autoriser le port 22 (SSH)
3. Autoriser le port 80 (HTTP)
4. Autoriser le port 443 (HTTPS)
5. Bloquer TOUT le reste en entrée
6. Activer UFW
```

**Pourquoi le port 22 est autorisé ?** Sans SSH, vous ne pourriez plus vous connecter au serveur. Ansible en a besoin pour fonctionner.

### `roles/app/vars/main.yml` — Variables

```yaml
app_dir: /opt/cloud1                        # dossier de l'application sur le serveur
domain_name: culoud.duckdns.org             # nom de domaine
mysql_database: wordpress                    # nom de la base de données
mysql_user: wp_user                         # utilisateur MySQL
mysql_root_password: "{{ vault_mysql_root_password }}"  # → vient du vault
mysql_password: "{{ vault_mysql_password }}"              # → vient du vault
```

Les variables `{{ }}` sont des templates Jinja2. Ansible les remplace au moment de l'exécution.

### `roles/app/vars/vault.yml` — Secrets chiffrés

```yaml
vault_mysql_root_password: "mot_de_passe_root"
vault_mysql_password: "mot_de_passe_user"
```

Ce fichier est **chiffré avec `ansible-vault`**. Même si quelqu'un vole le code, il ne peut pas lire les mots de passe sans la clé (`.vault_pass`).

### `roles/app/templates/docker-compose.yml.j2` — Conteneurs

```yaml
services:
  nginx:
    image: nginx:alpine              # image officielle légère (basée sur Alpine Linux)
    ports:
      - "80:80"                      # hôte:conteneur → HTTP
      - "443:443"                    # hôte:conteneur → HTTPS
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro   # configuration
      - ./nginx/ssl:/etc/nginx/ssl:ro                  # certificats TLS
      - ./nginx/certbot-webroot:/var/www/certbot:ro    # vérification Let's Encrypt
      - wp_data:/var/www/html:ro     # fichiers WordPress (lecture seule pour nginx)
    networks:
      - frontend                     # communique avec wordpress et phpmyadmin
    restart: always                  # redémarre automatiquement si crash ou reboot
    depends_on:
      - wordpress
      - phpmyadmin

  wordpress:
    image: wordpress:php8.3-fpm-alpine  # PHP-FPM (pas Apache), plus léger
    environment:                        # variables d'environnement → configuration WordPress
      WORDPRESS_DB_HOST: mysql          # nom du conteneur MySQL = nom d'hôte
      WORDPRESS_DB_NAME: wordpress
      WORDPRESS_DB_USER: wp_user
      WORDPRESS_DB_PASSWORD: "{{ mysql_password }}"  # vient du vault
    volumes:
      - wp_data:/var/www/html       # données persistantes (articles, images, plugins)
    networks:
      - frontend                    # pour que nginx puisse l'atteindre
      - backend                     # pour atteindre MySQL
    restart: always
    depends_on:
      - mysql                       # attend que MySQL soit prêt

  mysql:
    image: mysql:8.4
    environment:
      MYSQL_ROOT_PASSWORD: "{{ mysql_root_password }}"
      MYSQL_DATABASE: wordpress
      MYSQL_USER: wp_user
      MYSQL_PASSWORD: "{{ mysql_password }}"
    volumes:
      - db_data:/var/lib/mysql      # données persistantes (base de données)
    networks:
      - backend                     # UNIQUEMENT backend → pas exposé à internet
    restart: always
    # PAS de ports: → 3306 inaccessible depuis l'extérieur

  phpmyadmin:
    image: phpmyadmin:apache
    environment:
      PMA_HOST: mysql               # se connecte à MySQL via le réseau backend
    networks:
      - frontend                    # nginx le contacte ici
      - backend                     # il contacte MySQL ici
    restart: always
    depends_on:
      - mysql

volumes:
  db_data:    # survit aux redémarrages et reconstructions de conteneurs
  wp_data:

networks:
  frontend:   # réseau "public" (interne à Docker)
  backend:    # réseau "privé" (interne à Docker), isole MySQL
```

**Pourquoi 2 réseaux Docker ?** MySQL est uniquement dans `backend`. nginx est uniquement dans `frontend`. wordpress et phpmyadmin sont dans les deux (ils font le pont). Résultat : nginx ne peut **pas** contacter MySQL directement → sécurité.

### `roles/app/templates/nginx.conf.j2` — Reverse proxy + TLS

```nginx
events {}
http {
    # ── Bloc WordPress en HTTP (port 80) ──
    server {
        listen 80;
        server_name culoud.duckdns.org;

        # Exception : Let's Encrypt doit pouvoir vérifier le domaine en HTTP
        location /.well-known/acme-challenge/ {
            root /var/www/certbot;
        }
        # Tout le reste → redirigé en HTTPS
        location / {
            return 301 https://$host$request_uri;
        }
    }

    # ── Bloc WordPress en HTTPS (port 443) ──
    server {
        listen 443 ssl;
        server_name culoud.duckdns.org;

        ssl_certificate     /etc/nginx/ssl/cert.pem;
        ssl_certificate_key /etc/nginx/ssl/key.pem;

        root /var/www/html;
        index index.php;

        # Pretty permalinks WordPress : toute URL → index.php si le fichier n'existe pas
        location / {
            try_files $uri $uri/ /index.php?$args;
        }

        # Fichiers PHP → transmis au conteneur wordpress (FastCGI sur le port 9000)
        location ~ \.php$ {
            fastcgi_pass   wordpress:9000;
            fastcgi_param  SCRIPT_FILENAME $document_root$fastcgi_script_name;
            include        fastcgi_params;
        }
    }

    # ── phpMyAdmin (même principe, mais en proxy HTTP au lieu de FastCGI) ──
    server {
        listen 80;
        server_name phpmyadmin.culoud.duckdns.org;
        location /.well-known/acme-challenge/ { root /var/www/certbot; }
        location / { return 301 https://$host$request_uri; }
    }

    server {
        listen 443 ssl;
        server_name phpmyadmin.culoud.duckdns.org;

        ssl_certificate     /etc/nginx/ssl/cert.pem;
        ssl_certificate_key /etc/nginx/ssl/key.pem;

        location / {
            proxy_pass http://phpmyadmin:80;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }
    }
}
```

**Pourquoi FastCGI pour WordPress et proxy HTTP pour phpMyAdmin ?**
- WordPress utilise PHP-FPM, qui communique via le protocole FastCGI (port 9000)
- phpMyAdmin a son propre serveur Apache intégré, nginx le proxy en HTTP classique

**Pourquoi `try_files` ?** Sans ça, les "pretty permalinks" WordPress (/mon-article) ne fonctionnent pas et renvoient une 404.

### `roles/app/tasks/main.yml` — Déploiement de l'application

```
1.  Charger les secrets vault
2.  Créer le dossier /opt/cloud1
3.  Créer les sous-dossiers nginx, ssl, certbot-webroot
4.  Générer un certificat auto-signé → fallback de sécurité
5.  Déployer docker-compose.yml
6.  Installer certbot (snap) → pour Let's Encrypt
7.  Déployer nginx.conf (inclut .well-known pour LE)
8.  Créer le dossier .well-known/acme-challenge
9.  Démarrer les conteneurs (docker compose up -d)
10. Vérifier si le domaine pointe vers l'instance
    ├── OUI → Obtenir le certificat Let's Encrypt (certbot --webroot)
    │         Copier fullchain.pem et privkey.pem
    │         Redémarrer nginx
    │         Configurer le renouvellement automatique (cron)
    └── NON → Garder le certificat auto-signé (pour les tests/défense)
```

### `roles/app/handlers/main.yml` — Actions déclenchées

```yaml
- name: restart nginx
  command: docker compose restart nginx
  args:
    chdir: "{{ app_dir }}"
```

Un **handler** est une tâche qui ne s'exécute que si elle est notifiée (`notify`). Ici, on redémarre nginx uniquement quand le certificat change, pas à chaque run.

---

## Déploiement sur une nouvelle machine (évaluateur)

Pour déployer sur une nouvelle instance Ubuntu 22.04 :

1. **Modifier l'inventaire** (`inventory/hosts.yml`) :
   - `ansible_host` : l'IP de la nouvelle instance
   - `ansible_ssh_private_key_file` : chemin vers la clé privée SSH

2. **Modifier le domaine** (`roles/app/vars/main.yml`) :
   - `domain_name` : le nom de domaine pointant vers l'instance (ou un domaine factice)

3. **Placer la clé publique SSH** sur l'instance :
   ```bash
   ssh-copy-id ubuntu@<IP>
   ```

4. **Lancer le playbook** :
   ```bash
   ansible-playbook playbook.yml --vault-password-file .vault_pass
   ```

Si le domaine pointe vers l'instance → Let's Encrypt automatique.
Sinon → certificat auto-signé (le site reste fonctionnel).

---

## Commandes utiles

```bash
# Tester la connexion SSH
ansible all -m ping

# Déployer
ansible-playbook playbook.yml --vault-password-file .vault_pass
ansible-playbook playbook.yml --ask-vault-pass

# Modifier les secrets
EDITOR=nano ansible-vault edit roles/app/vars/vault.yml --vault-password-file .vault_pass

# Voir l'état des conteneurs
ansible all -m shell -a "cd /opt/cloud1 && docker compose ps"

# Voir les logs
ansible all -m shell -a "cd /opt/cloud1 && docker compose logs"

# Vérifier le firewall
ansible all -b -m shell -a "ufw status verbose"
```

---

## Idempotence

Le playbook est **idempotent** : le lancer 10 fois produit le même résultat que le lancer 1 fois.

- `creates:` empêche de régénérer le certificat s'il existe déjà
- Les modules `apt`, `file`, `template` détectent si une modification est nécessaire
- `docker compose up -d` ne recrée que ce qui a changé

---

## Fallback Let's Encrypt → auto-signé

Le playbook détecte automatiquement si le domaine peut obtenir un certificat Let's Encrypt :

1. Récupère l'IP publique de l'instance (`curl api.ipify.org`)
2. Résout le domaine (`dig +short`)
3. Si les IPs correspondent → Let's Encrypt (certificat reconnu)
4. Si les IPs ne correspondent pas → certificat auto-signé (fallback)

Cela permet à l'évaluateur de déployer le playbook sur **sa propre machine** même si son domaine ne pointe pas encore vers son IP. Le site fonctionnera avec un certificat auto-signé, et il pourra activer Let's Encrypt plus tard en pointant son domaine.

---

## Glossaire

| Terme | Définition |
|-------|------------|
| **Ansible** | Outil d'automatisation qui exécute des tâches sur des serveurs distants via SSH |
| **Playbook** | Fichier YAML qui liste les rôles à exécuter |
| **Rôle** | Ensemble de tâches, templates, variables pour une fonction (docker, firewall, app) |
| **Template Jinja2** | Fichier avec des `{{ variables }}` qu'Ansible remplace avant de le copier |
| **Ansible Vault** | Chiffrement des fichiers contenant des secrets |
| **Docker** | Plateforme qui exécute des applications dans des conteneurs isolés |
| **Docker Compose** | Outil pour définir et lancer plusieurs conteneurs ensemble |
| **Conteneur** | Processus isolé avec son propre système de fichiers, réseau, etc. |
| **Volume Docker** | Stockage persistant qui survit aux redémarrages des conteneurs |
| **nginx** | Serveur web léger utilisé comme reverse proxy |
| **Reverse proxy** | Serveur qui reçoit les requêtes et les transmet au bon service |
| **TLS/SSL** | Protocole de chiffrement (le "s" dans HTTPS) |
| **Let's Encrypt** | Autorité de certification gratuite qui fournit des certificats TLS reconnus |
| **Certificat auto-signé** | Certificat généré soi-même, non reconnu par les navigateurs |
| **FastCGI** | Protocole de communication entre nginx et PHP-FPM |
| **UFW** | Pare-feu simple pour Linux (Uncomplicated FireWall) |
| **Idempotence** | Propriété : exécuter N fois = même résultat qu'1 fois |
