<?php
require_once dirname(__FILE__).'/include/config.inc.php';
$app    = $_GET["app"];
$hostid = $_GET["hostid"];
if(($DB['TYPE'] == "POSTGRESQL") or ($DB['TYPE'] == "MYSQL")) {
        $result = DBselect("select ip from interface where hostid=$hostid limit 1");
        $row = DBfetch($result);
        $ipaddress = $row['ip'];
} else {
        exit("Base nao suportada");
}
if ($app == "web")
        header("Location: http://$ipaddress");

if ($app == "winbox")
        header("Location: winbox:$ipaddress");

if ($app == "putty")
        header("Location: putty:$ipaddress");

if ($app == "winmtr")
        header("Location: winmtr:$ipaddress");

if ($app == "mtupath")
        header("Location: mtupath:$ipaddress");

if ($app == "rdp")
        header("Location: rdp:$ipaddress");
?>