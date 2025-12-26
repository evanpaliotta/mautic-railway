# Custom Mautic Dockerfile with SES API mailer support
# Fixes: Railway blocks SMTP ports, must use API-based email transport
FROM mautic/mautic:5-apache

# Fix the Apache MPM configuration error
# Disable conflicting MPM modules and ensure only one is loaded
RUN a2dismod mpm_event 2>/dev/null || true && \
    a2dismod mpm_worker 2>/dev/null || true && \
    a2enmod mpm_prefork && \
    echo "Apache MPM fixed to use prefork only"

# Ensure PHP mod is enabled for prefork
RUN a2enmod php || a2enmod php8.1 || a2enmod php8.2 || echo "PHP module already enabled"

# Create composer cache directory for www-data user
RUN mkdir -p /var/www/.composer/cache && \
    chown -R www-data:www-data /var/www/.composer

# Install API-based mailer bridges as www-data user
USER www-data
WORKDIR /var/www/html

# Set composer home to use the cache directory we created
ENV COMPOSER_HOME=/var/www/.composer

# Install the Amazon SES and SendGrid mailers
RUN composer require symfony/amazon-mailer symfony/sendgrid-mailer \
    --no-interaction \
    --no-scripts \
    --prefer-dist \
    --optimize-autoloader

# Regenerate autoloader with optimizations
RUN composer dump-autoload --optimize --classmap-authoritative

# Switch back to root to clear caches and fix permissions
USER root

# Clear all Mautic caches to ensure fresh state with new packages
RUN rm -rf /var/www/html/var/cache/* && \
    rm -rf /var/www/html/var/logs/* && \
    mkdir -p /var/www/html/var/cache /var/www/html/var/logs && \
    chown -R www-data:www-data /var/www/html/var

# Create Mautic cron script that runs all required jobs
RUN cat > /usr/local/bin/mautic-cron.sh << 'CRONSCRIPT'
#!/bin/bash
# Mautic Cron Jobs - runs every 2 minutes in background
# Wait for Mautic to fully initialize
sleep 120
while true; do
    echo "[$(date)] Running Mautic cron jobs..."
    php /var/www/html/bin/console mautic:segments:update --env=prod 2>&1 || true
    php /var/www/html/bin/console mautic:campaigns:update --env=prod 2>&1 || true
    php /var/www/html/bin/console mautic:campaigns:trigger --env=prod 2>&1 || true
    php /var/www/html/bin/console mautic:emails:send --env=prod 2>&1 || true
    php /var/www/html/bin/console mautic:broadcasts:send --env=prod 2>&1 || true
    echo "[$(date)] Cron jobs complete. Sleeping 2 minutes..."
    sleep 120
done
CRONSCRIPT
RUN chmod +x /usr/local/bin/mautic-cron.sh

# Create a wrapper script that starts cron in background then runs Apache
RUN cat > /usr/local/bin/mautic-start.sh << 'STARTSCRIPT'
#!/bin/bash
echo "Starting Mautic cron jobs in background..."
nohup /usr/local/bin/mautic-cron.sh > /var/log/mautic-cron.log 2>&1 &
echo "Starting Apache..."
exec apache2-foreground
STARTSCRIPT
RUN chmod +x /usr/local/bin/mautic-start.sh

# Create log file for cron
RUN touch /var/log/mautic-cron.log && chown www-data:www-data /var/log/mautic-cron.log

# Use the custom start script
CMD ["/usr/local/bin/mautic-start.sh"]
