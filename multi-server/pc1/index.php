<?php
ini_set('display_errors', 1);
error_reporting(E_ALL);

$mysqli = new mysqli("localhost", "fsuser", "YOUR_DB_PASSWORD", "freeswitch_db");
if ($mysqli->connect_errno) {
    http_response_code(500);
    exit;
}
const SIP_PASSWORD = "1234";
// Balance check endpoint: /?action=check_balance&ext=1000
if (isset($_GET['action']) && $_GET['action'] === 'check_balance') {
    $ext = $_GET['ext'] ?? '';
    $stmt = $mysqli->prepare("SELECT balance FROM extensions WHERE extension = ?");
    $stmt->bind_param("s", $ext);
    $stmt->execute();
    $row = $stmt->get_result()->fetch_assoc();
    header('Content-Type: text/plain');
    echo $row ? $row['balance'] : '0';
    exit;
}

// Deduct endpoint: /?action=deduct&ext=1000&seconds=12
if (isset($_GET['action']) && $_GET['action'] === 'deduct') {
    $ext = $_GET['ext'] ?? '';
    $secs = (int)($_GET['seconds'] ?? 0);
    $stmt = $mysqli->prepare("UPDATE extensions SET balance = GREATEST(balance - ?, 0) WHERE extension = ?");
    $stmt->bind_param("is", $secs, $ext);
    $stmt->execute();
    header('Content-Type: text/plain');
    echo "OK";
    exit;
}

$section = $_POST['section'] ?? '';
$user    = $_POST['user'] ?? '';
$domain  = $_POST['domain'] ?? '';

header('Content-Type: text/xml');
file_put_contents('/tmp/xmlcurl_debug.log', date('c') . " FULL POST: " . print_r($_POST, true) . "\n", FILE_APPEND);

if ($section === 'directory' && $user !== '') {
    $stmt = $mysqli->prepare("SELECT extension, balance FROM extensions WHERE extension = ?");
    $stmt->bind_param("s", $user);
    $stmt->execute();
    $result = $stmt->get_result();
    $row = $result->fetch_assoc();

    if ($row) {
        $xml  = "<document type=\"freeswitch/xml\">\n";
        $xml .= "  <section name=\"directory\">\n";
        $xml .= "    <domain name=\"" . $domain . "\">\n";
        $xml .= "      <groups>\n";
        $xml .= "        <group name=\"default\">\n";
        $xml .= "          <users>\n";
        $xml .= "            <user id=\"" . $row['extension'] . "\">\n";
        $xml .= "              <params>\n";
        $xml .= "                <param name=\"password\" value=\"" . SIP_PASSWORD . "\"/>\n";
        $xml .= "                <param name=\"dial-string\" value=\"{presence_id=" . $row['extension'] . "@\${domain_name}}\${sofia_contact(" . $row['extension'] . "@\${domain_name})}\"/>\n";
        $xml .= "              </params>\n";
        $xml .= "              <variables>\n";
        $xml .= "                <variable name=\"accountcode\" value=\"" . $row['extension'] . "\"/>\n";
        $xml .= "                <variable name=\"user_context\" value=\"default\"/>\n";
        $xml .= "                <variable name=\"effective_caller_id_name\" value=\"Extension " . $row['extension'] . "\"/>\n";
        $xml .= "                <variable name=\"effective_caller_id_number\" value=\"" . $row['extension'] . "\"/>\n";
        $xml .= "              </variables>\n";
        $xml .= "            </user>\n";
        $xml .= "          </users>\n";
        $xml .= "        </group>\n";
        $xml .= "      </groups>\n";
        $xml .= "    </domain>\n";
        $xml .= "  </section>\n";
        $xml .= "</document>\n";
        echo $xml;
        exit;
    }
}

echo "<document type=\"freeswitch/xml\">\n";
echo "  <section name=\"result\">\n";
echo "    <result status=\"not found\"/>\n";
echo "  </section>\n";
echo "</document>\n";
