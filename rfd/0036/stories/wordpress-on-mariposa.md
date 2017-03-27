# WordPress on Mariposa

```yaml
cns
    namespace:
        public: mydomain.example.com
    primary_service: nginx
    ttl: 5s
services:
    wordpress:
        description: A demo version of WordPress for easy scaling.
        service_type: continuous
        compute_type: docker
        image: autopilotpattern/wordpress:latest
        containerpilot: true
        resources:
            package: g4-highcpu-1G
        placement:
            cn:
                - service!=~ {{ .this.service }}
                - project!=~ {{ .this.project }}
        volumes:
            - user-data:/var/www/html/content/uploads
        environment:
            CONSUL={{ .this.project.cns.private.consul }}
            # please include the scheme http:// or https:// in the URL variable
            WORDPRESS_URL=https://{{ .this.project.cns.public }}
            WORDPRESS_SITE_TITLE=Autopilot Pattern WordPress test site
            WORDPRESS_ADMIN_EMAIL=user@example.net
            WORDPRESS_ADMIN_USER={{ .this.meta.admin.user }}
            WORDPRESS_ADMIN_PASSWORD={{ .this.meta.admin.pass }}
            WORDPRESS_ACTIVE_THEME={{ .this.meta.theme }}
            WORDPRESS_CACHE_KEY_SALT={{ .this.meta.salt }}
            WORDPRESS_AUTH_KEY={{ .this.meta.salt }}
            WORDPRESS_SECURE_AUTH_KEY={{ .this.meta.salt }}
            WORDPRESS_LOGGED_IN_KEY={{ .this.meta.salt }}
            WORDPRESS_NONCE_KEY={{ .this.meta.salt }}
            WORDPRESS_AUTH_SALT={{ .this.meta.salt }}
            WORDPRESS_SECURE_AUTH_SALT={{ .this.meta.salt }}
            WORDPRESS_LOGGED_IN_SALT={{ .this.meta.salt }}
            WORDPRESS_NONCE_SALT={{ .this.meta.salt }}
            MYSQL_USER={{ .this.meta.mysql.user }}
            MYSQL_PASSWORD={{ .this.meta.mysql.user }}
            MYSQL_DATABASE={{ .this.meta.mysql.db }}

    consul:
        description: Consul is the service catalog that helps discovery between the components.
        image: autopilotpattern/consul:latest
        command: >
            # Change "-bootstrap" to "-bootstrap-expect 3", then scale to 3 or more to
            # turn this into an HA Consul raft.
            /usr/local/bin/containerpilot
            /bin/consul agent -server
            -bootstrap-expect 3
            -config-dir=/etc/consul
            -ui-dir /ui
        containerpilot: true
        resources:
            package: g4-highcpu-128m
        placement:
            cn:
                - service!=~ {{ .this.service }}
                - project!=~ {{ .this.project }}
        environment:
            CONSUL={{ .this.project.cns.private.consul }}

    mysql:
        Description:
            The MySQL database will automatically cluster and scale.\
            See https://www.joyent.com/blog/dbaas-simplicity-no-lock-in
        image: autopilotpattern/mysql:latest
        containerpilot: true
        resources:
            package: g4-general-4g
        placement:
            cn:
                - service!=~ {{ .this.service }}
                - project!=~ {{ .this.project }}
        environment:
            CONSUL={{ .this.project.cns.private.consul }}
            MYSQL_USER={{ .this.meta.mysql.user }}
            MYSQL_PASSWORD={{ .this.meta.mysql.user }}
            MYSQL_DATABASE={{ .this.meta.mysql.db }}
            # MySQL replication user, should be different from above
            MYSQL_REPL_USER={{ .this.meta.mysql.replication.user }}
            MYSQL_REPL_USER={{ .this.meta.mysql.replication.password }}
            # Environment variables for backups to Manta
            MANTA_BUCKET={{ .this.project.name }}/stor/mysql
            MANTA_URL=https://us-east.manta.joyent.com
            MANTA_USER={{ .this.project.organization }}

    memcached:
        description: 
            Memcached is a high performance object cache.\
            Run as many of these as you have database replicas.
        image: autopilotpattern/memcached:latest
        containerpilot: true
        resources:
            package: g4-highcpu-512m
        placement:
            cn:
                - service!=~ {{ .this.service }}
                - project!=~ {{ .this.project }}
        environment:
            CONSUL={{ .this.project.cns.private.consul }}
    
    nginx:
        description: The load-balancing tier and reverse proxy.
        image: autopilotpattern/wordpress-nginx:latest
        containerpilot: true
        resources:
            package: g4-highcpu-512m
        ports:
            - 80
            - 443
        cns:
            services:
                - nginx
            ttl: 24h
            hysteresis: 2h
        environment:
            CONSUL={{ .this.project.cns.private.consul }}
            # Nginx LetsEncrypt (ACME) config
            # be sure ACME_DOMAIN host and WORDPRESS_URL host are the same
            # if using automated SSL via LetsEncrypt
            ACME_DOMAIN={{ .this.project.cns.public }}
            ACME_ENV=production

    prometheus:
        description:
            Prometheus is an open source performance monitoring tool.\
            It is included here for demo purposes and is not required.
        image: autopilotpattern/prometheus:latest
        containerpilot: true
        resources:
            package: g4-highcpu-512m
            max_instances=1
        placement:
            cn:
                - service!=~ {{ .this.service }}
                - project!=~ {{ .this.project }}
        environment:
            CONSUL={{ .this.project.cns.private.consul }}

volumes:
    user-data:
        description: User-uploaded data
        size: 10g
        placement:
            cn:
                - volume!=~ {{ .this.volume }}
                - project!=~ {{ .this.project }}
```