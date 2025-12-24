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

# Install API-based mailer bridges as www-data user (Mautic's expected user)
# This prevents permission and path resolution issues
USER www-data
WORKDIR /var/www/html

# Install the Amazon SES and SendGrid mailers
# Using --no-scripts initially to avoid permission issues, then running dump-autoload
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

# Create a script to warm up caches on container start (optional)
RUN echo '#!/bin/bash\nphp /var/www/html/bin/console cache:clear --env=prod 2>/dev/null || true\nexec apache2-foreground' > /usr/local/bin/mautic-start.sh && \
    chmod +x /usr/local/bin/mautic-start.sh

# Use the custom start script
CMD ["/usr/local/bin/mautic-start.sh"]
