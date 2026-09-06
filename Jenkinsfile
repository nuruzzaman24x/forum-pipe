pipeline {
    agent any

    environment {
        APP_URL          = "http://172.17.0.233"
        APP_ENV          = "production"
        APP_DEBUG        = "false"

        DB_HOST          = "127.0.0.1"
        DB_DATABASE      = "forum"
        DB_USERNAME      = "forum_user"
        DB_PASSWORD = credentials('forum-db-password')

        DEPLOY_PATH      = "/var/www/forum-pipe"
        SSH_USER         = "deploy"
        DEPLOY_SERVER    = "172.17.0.233"
        PHP_BIN          = "php8.1"
    }

    stages {

        stage('Checkout') {
            steps {
                git branch: 'master',
                    credentialsId: 'github-access',
                    url: 'https://github.com/nuruzzaman24x/forum-pipe.git'
            }
        }

        stage('Provision Worker') {
            steps {
                sh '''
                    scp -o StrictHostKeyChecking=no deploy/provision-worker.sh ${SSH_USER}@${DEPLOY_SERVER}:/tmp/provision-worker.sh
                    ssh -o StrictHostKeyChecking=no ${SSH_USER}@${DEPLOY_SERVER} "sudo bash /tmp/provision-worker.sh"
                '''
            }
        }
        stage('Ensure PHP Extensions') {
            steps {
                sh '''
                    ssh -o StrictHostKeyChecking=no ${SSH_USER}@${DEPLOY_SERVER} \
                        "php8.1 -m | grep -qi sqlite3 || (sudo apt-get update && sudo apt-get install -y php8.1-sqlite3 && sudo systemctl restart php8.1-fpm)"
                '''
            }
        }

        stage('Verify PHP Version') {
            steps {
                sh '''
                    ssh -o StrictHostKeyChecking=no ${SSH_USER}@${DEPLOY_SERVER} \
                        "${PHP_BIN} -v | grep -q '8.1' || (echo 'ERROR: PHP 8.1 not found on deploy server' && exit 1)"
                '''
            }
        }

        stage('Sync Code to Worker') {
            steps {
                sh '''
                    ssh -o StrictHostKeyChecking=no ${SSH_USER}@${DEPLOY_SERVER} "mkdir -p ${DEPLOY_PATH} && sudo chown -R ${SSH_USER}. ${DEPLOY_PATH}"
                    rsync -avhP -e "ssh -o StrictHostKeyChecking=no" --exclude '.git/' . ${SSH_USER}@${DEPLOY_SERVER}:${DEPLOY_PATH}
                '''
            }
        }

        stage('Configure .env') {
            steps {
                sh '''
                    ssh -o StrictHostKeyChecking=no ${SSH_USER}@${DEPLOY_SERVER} bash -s <<EOF
                        cd ${DEPLOY_PATH}
                        cp -n .env.example .env
                        sed -i "s|^APP_URL=.*|APP_URL=${APP_URL}|" .env
                        sed -i "s|^APP_ENV=.*|APP_ENV=${APP_ENV}|" .env
                        sed -i "s|^APP_DEBUG=.*|APP_DEBUG=${APP_DEBUG}|" .env
                        sed -i "s|^DB_HOST=.*|DB_HOST=${DB_HOST}|" .env
                        sed -i "s|^DB_DATABASE=.*|DB_DATABASE=${DB_DATABASE}|" .env
                        sed -i "s|^DB_USERNAME=.*|DB_USERNAME=${DB_USERNAME}|" .env
                        sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${DB_PASSWORD}|" .env
EOF
                '''
            }
        }

        stage('Composer Install') {
            steps {
                sh '''
                    ssh -o StrictHostKeyChecking=no ${SSH_USER}@${DEPLOY_SERVER} \
                        "cd ${DEPLOY_PATH} && ${PHP_BIN} /usr/local/bin/composer install --no-dev --optimize-autoloader"
                '''
            }
        }

        stage('Key Generate') {
            steps {
                sh '''
                    ssh -o StrictHostKeyChecking=no ${SSH_USER}@${DEPLOY_SERVER} \
                        "cd ${DEPLOY_PATH} && ${PHP_BIN} artisan key:generate --force && ${PHP_BIN} artisan config:clear && ${PHP_BIN} artisan route:clear && ${PHP_BIN} artisan cache:clear && ${PHP_BIN} artisan view:clear"
                '''
            }
        }

        stage('PHPUnit Tests') {
            steps {
                sh '''
                    ssh -o StrictHostKeyChecking=no ${SSH_USER}@${DEPLOY_SERVER} \
                        "cd ${DEPLOY_PATH} && ${PHP_BIN} /usr/local/bin/composer install --optimize-autoloader && ${PHP_BIN} artisan test"
                '''
            }
        }

        stage('Approval') {
            steps {
                input message: "Do you approve this deployment to ${DEPLOY_SERVER}?", ok: "Deploy"
            }
        }

        stage('Migrate & Fix Permissions') {
            steps {
                sh '''
                    ssh -o StrictHostKeyChecking=no ${SSH_USER}@${DEPLOY_SERVER} bash -s <<EOF
                        cd ${DEPLOY_PATH}
                        ${PHP_BIN} artisan migrate --force
                        sudo chown -R www-data:www-data storage bootstrap/cache
                        sudo chmod -R 775 storage bootstrap/cache
EOF
                '''
            }
        }

        stage('Reload Web Server') {
            steps {
                sh '''
                    ssh -o StrictHostKeyChecking=no ${SSH_USER}@${DEPLOY_SERVER} \
                        "sudo systemctl restart php8.1-fpm && sudo nginx -t && sudo systemctl reload nginx"
                '''
            }
        }
    }

    post {
        success {
            echo "Deployment successful! Visit ${APP_URL}"
        }
        failure {
            echo "Pipeline failed. Check the stage logs above for the exact error."
        }
        always {
            cleanWs()
        }
    }
}
