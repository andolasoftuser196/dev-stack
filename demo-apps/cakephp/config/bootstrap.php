<?php
declare(strict_types=1);

use Cake\Cache\Cache;
use Cake\Core\Configure;
use Cake\Datasource\ConnectionManager;

require_once __DIR__ . '/paths.php';
require_once dirname(__DIR__) . '/vendor/autoload.php';

/**
 * CakePHP 5 removed the global env() helper that 4.x provided, so a config file
 * carried over from 4.x dies with "Call to undefined function env()" - during
 * bootstrap, before any error handler exists, so it is a bare fatal with no
 * context at all. getenv() with an explicit default does the same job.
 */
function ssmd_env(string $key, ?string $default = null): ?string
{
    $v = getenv($key);
    return ($v === false || $v === '') ? $default : $v;
}

Configure::write('App', [
    'namespace' => 'App',
    'encoding' => 'UTF-8',
    'defaultLocale' => 'en_US',
    'base' => false,
    'dir' => 'src',
    'webroot' => 'webroot',
    'wwwRoot' => dirname(__DIR__) . '/webroot/',
    'paths' => ['templates' => [dirname(__DIR__) . '/templates/']],
]);
Configure::write('debug', true);

// Connection details come from the process environment, which ssmd injects. They
// are deliberately NOT read from a committed config file: an app whose database
// host lives in a file is an app that connects to the wrong one the first time
// somebody runs a second instance.
$isPostgres = str_contains((string)ssmd_env('DB_HOST'), 'postgres');
ConnectionManager::setConfig('default', [
    'className' => 'Cake\Database\Connection',
    'driver' => $isPostgres ? 'Cake\Database\Driver\Postgres' : 'Cake\Database\Driver\Mysql',
    'host' => ssmd_env('DB_HOST', 'postgres'),
    'port' => ssmd_env('DB_PORT', $isPostgres ? '5432' : '3306'),
    'username' => ssmd_env('DB_USERNAME', 'app'),
    'password' => ssmd_env('DB_PASSWORD', 'app'),
    'database' => ssmd_env('DB_DATABASE', 'app_dev'),
    'timezone' => 'UTC',
    'cacheMetadata' => false,
]);

// One Redis logical database per instance, and a per-instance key prefix on top.
// Sharing the server is fine; sharing keyspace is what produces a cached value
// from another branch and a day spent not suspecting the cache.
Cache::setConfig('default', [
    'className' => 'Cake\Cache\Engine\RedisEngine',
    'host' => ssmd_env('REDIS_HOST', 'redis'),
    'port' => (int)ssmd_env('REDIS_PORT', '6379'),
    'database' => (int)ssmd_env('REDIS_DB', '0'),
    'prefix' => ssmd_env('CACHE_PREFIX', 'ssmd_'),
    'duration' => '+30 seconds',
]);
