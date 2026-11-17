<?php
$b = file_get_contents('php://input');
header('X-Body-Md5: ' . md5($b));
echo strlen($b);
