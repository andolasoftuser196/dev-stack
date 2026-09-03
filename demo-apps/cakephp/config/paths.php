<?php
declare(strict_types=1);

/**
 * CakePHP's path constants.
 *
 * The framework requires these to exist before any of its code runs — App.php
 * dereferences APP directly — and they come from the application skeleton, not
 * from the framework package. A project assembled by hand without them dies
 * with `Undefined constant "Cake\Core\APP"` from deep inside vendor/, which
 * points nowhere near the actual omission.
 */
define('ROOT', dirname(__DIR__));
define('APP_DIR', 'src');
define('APP', ROOT . DIRECTORY_SEPARATOR . APP_DIR . DIRECTORY_SEPARATOR);
define('CONFIG', ROOT . DIRECTORY_SEPARATOR . 'config' . DIRECTORY_SEPARATOR);
define('WWW_ROOT', ROOT . DIRECTORY_SEPARATOR . 'webroot' . DIRECTORY_SEPARATOR);
define('TESTS', ROOT . DIRECTORY_SEPARATOR . 'tests' . DIRECTORY_SEPARATOR);
define('TMP', ROOT . DIRECTORY_SEPARATOR . 'tmp' . DIRECTORY_SEPARATOR);
define('LOGS', ROOT . DIRECTORY_SEPARATOR . 'logs' . DIRECTORY_SEPARATOR);
define('CACHE', TMP . 'cache' . DIRECTORY_SEPARATOR);
define('CAKE_CORE_INCLUDE_PATH', ROOT . '/vendor/cakephp/cakephp');
define('CORE_PATH', CAKE_CORE_INCLUDE_PATH . DIRECTORY_SEPARATOR);
define('CAKE', CORE_PATH . 'src' . DIRECTORY_SEPARATOR);
