# HTTPS on the V2 development EC2

The development EC2 uses its Elastic IP directly, so no DNS record is needed.
Let's Encrypt IP address certificates are short-lived (160 hours); Certbot must
renew them automatically. Keep inbound TCP 80 open for HTTP-01 validation and
allow inbound TCP 443 for HTTPS.

## Initial certificate setup

1. Apply the `dev_app_https` security-group rule from `test-infra/security_group.tf`.
2. Copy `docker-compose.yaml`, both Nginx configs, and
   `reload-nginx-after-renewal.sh` from this directory to the EC2 under
   `/opt/stockspoon-v2`. Keep `nginx/default.conf` as
   `/opt/stockspoon-v2/nginx/default.conf.https`, then temporarily activate the
   bootstrap config. Do not change `.env` as part of this setup.
3. Install Certbot 5.4 or newer and temporarily activate the HTTP bootstrap
   config:

   ```sh
   sudo snap install --classic certbot
   sudo ln -s /snap/bin/certbot /usr/local/bin/certbot
   sudo mkdir -p /opt/stockspoon-v2/certbot/www
   sudo cp /opt/stockspoon-v2/nginx/default-http-bootstrap.conf \
     /opt/stockspoon-v2/nginx/default.conf
   cd /opt/stockspoon-v2
   sudo docker compose --env-file .env -f docker-compose.yaml \
     up -d --no-deps nginx
   ```

4. Issue the short-lived IP certificate. Replace the example IP with the EC2
   Elastic IP:

   ```sh
   sudo certbot certonly --non-interactive --agree-tos \
     --register-unsafely-without-email \
     --preferred-profile shortlived \
     --webroot --webroot-path /opt/stockspoon-v2/certbot/www \
     --ip-address 54.180.180.202 \
     --cert-name stockspoon-v2-dev
   ```

5. Activate the TLS Nginx config and install the renewal hook:

   ```sh
   sudo cp /opt/stockspoon-v2/nginx/default.conf.https \
     /opt/stockspoon-v2/nginx/default.conf
   sudo install -D -m 0755 \
     /opt/stockspoon-v2/reload-nginx-after-renewal.sh \
     /etc/letsencrypt/renewal-hooks/deploy/stockspoon-v2-dev-nginx
   sudo docker compose --env-file .env -f docker-compose.yaml \
     up -d --no-deps nginx
   ```

Certbot's snap installation supplies automatic renewal scheduling. Confirm a
renewal timer is present with `systemctl list-timers --all | grep -i certbot`.
The deploy hook validates and reloads Nginx after each successful renewal. The
Nginx config serves both HTTP and HTTPS; HTTP stays available during rollout.
