<?php
ini_set('display_errors', 1);
error_reporting(E_ALL);

$mysqli = new mysqli("localhost", "fsuser", "Fs2026!Secure", "freeswitch_db");
if ($mysqli->connect_errno) {
    http_response_code(500);
    exit;
}

$section = $_POST['section'] ?? '';
$user    = $_POST['user'] ?? '';
$domain  = $_POST['domain'] ?? '';

header('Content-Type: text/xml');
file_put_contents('/tmp/xmlcurl_debug.log', date('c') . " FULL POST: " . print_r($_POST, true) . "\n", FILE_APPEND);
if ($section === 'directory' && $user !== '') {
    $stmt = $mysqli->prepare("SELECT * FROM extensions WHERE extension = ?");
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
        $xml .= "                <param name=\"password\" value=\"" . $row['password'] . "\"/>\n";
	$xml .= "                <param name=\"dial-string\" value=\"{presence_id=" . $row['extension'] . "@\${domain_name}}\${sofia_contact(" . $row['extension'] . "@\${domain_name})}\"/>\n";
        $xml .= "              </params>\n";
        $xml .= "              <variables>\n";
        $xml .= "                <variable name=\"accountcode\" value=\"" . $row['extension'] . "\"/>\n";
        $xml .= "                <variable name=\"user_context\" value=\"default\"/>\n";
        $xml .= "                <variable name=\"effective_caller_id_name\" value=\"" . $row['caller_id_name'] . "\"/>\n";
        $xml .= "                <variable name=\"effective_caller_id_number\" value=\"" . $row['caller_id_number'] . "\"/>\n";
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
