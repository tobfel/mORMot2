<?php header('X-Custom: yes'); http_response_code(isset($_GET['s']) ? (int)$_GET['s'] : 200);
echo $_SERVER['SCRIPT_NAME'], '|', $_SERVER['PATH_INFO'] ?? '', '|', $_SERVER['QUERY_STRING'], '|', PHP_VERSION, '|', ($_SERVER['SERVER_SOFTWARE'] ?? '');
