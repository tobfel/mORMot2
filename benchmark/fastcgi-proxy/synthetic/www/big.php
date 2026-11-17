<?php
$n = isset($_GET['kb']) ? (int)$_GET['kb'] : 1024;
header('Content-Type: application/octet-stream');
echo str_repeat('x', $n * 1024);
