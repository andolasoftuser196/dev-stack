<?php
// Intentionally thin. Everything that varies between machines or instances
// comes from the process environment in bootstrap.php; a config file that
// hardcodes a host is a config file that connects to the wrong one.
return [
    'debug' => true,
    'App' => ['namespace' => 'App'],
    'Error' => ['errorLevel' => E_ALL, 'skipLog' => [], 'log' => true, 'trace' => true],
];
