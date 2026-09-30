# 1. Start MySQL
sudo systemctl start mysql

# 2. Verify PHP script syntax
php -l /home/nazmul/fs_xml_service/index.php

# 3. Start the PHP lookup service
sudo systemctl start fs-xml-service
