#!/bin/bash
# ISP, модуль 2, п.9-10: обратный прокси nginx и web-аутентификация для web.au-team.irpo
apt-get update && apt-get install -y nginx apache2-htpasswd

# Логин WEB, пароль P@ssw0rd, файл /etc/nginx/.htpasswd
htpasswd -bc /etc/nginx/.htpasswd WEB 'P@ssw0rd'

cat > /etc/nginx/sites-available.d/default.conf <<'EOF'
# web.au-team.irpo -> веб-приложение на HQ-SRV (через проброс 8080 на HQ-RTR), с паролем
server {
	listen 80;
	server_name web.au-team.irpo;

	location / {
		auth_basic "Restricted area";
		auth_basic_user_file /etc/nginx/.htpasswd;
		proxy_pass http://172.16.1.2:8080;
		proxy_set_header Host $host;
		proxy_set_header X-Real-IP $remote_addr;
		proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
		proxy_set_header X-Forwarded-Proto $scheme;
	}
}

# docker.au-team.irpo -> testapp на BR-SRV (через проброс 8080 на BR-RTR)
server {
	listen 80;
	server_name docker.au-team.irpo;

	location / {
		proxy_pass http://172.16.2.2:8080;
		proxy_set_header Host $host;
		proxy_set_header X-Real-IP $remote_addr;
		proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
		proxy_set_header X-Forwarded-Proto $scheme;
	}
}
EOF

ln -sf /etc/nginx/sites-available.d/default.conf /etc/nginx/sites-enabled.d/default.conf
nginx -t && systemctl enable --now nginx && systemctl restart nginx
