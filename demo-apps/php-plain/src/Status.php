<?php
declare(strict_types=1);

namespace Ssmd\Demo;

/**
 * The status page every ssmd demo app renders.
 *
 * Shared shape, one per runtime, so a single integration test can boot all
 * thirteen and assert the same things. Each probe opens a real connection -
 * "the container is running" is what `ssmd verify` already covers, and it is not
 * what anyone actually wants to know.
 */
final class Status
{
    /** @var list<string> */
    private array $lines = [];

    public function __construct(string $framework)
    {
        $this->lines[] = 'ssmd demo app';
        $this->lines[] = sprintf(
            'runtime=%s framework=%s version=%s',
            getenv('SSMD_RUNTIME') ?: 'frankenphp', $framework, PHP_VERSION
        );
        $this->lines[] = 'instance=' . (getenv('SSMD_INSTANCE') ?: 'main');
    }

    public function probeDatabase(): self
    {
        $name = getenv('DB_DATABASE') ?: '';
        if ($name === '') {
            return $this->add('database', 'skipped');
        }
        try {
            // The driver comes from DB_HOST's service name, which ssmd sets to the
            // engine. One code path for both engines keeps the demo honest about
            // the stack being engine-agnostic.
            $driver = str_contains(getenv('DB_HOST') ?: '', 'postgres') ? 'pgsql' : 'mysql';
            new \PDO(
                sprintf('%s:host=%s;port=%s;dbname=%s', $driver, getenv('DB_HOST'), getenv('DB_PORT'), $name),
                getenv('DB_USERNAME') ?: null,
                getenv('DB_PASSWORD') ?: null,
                [\PDO::ATTR_TIMEOUT => 5]
            );
            return $this->add('database', $name . ' ok');
        } catch (\Throwable $e) {
            return $this->add('database', $name . ' FAILED: ' . $e->getMessage());
        }
    }

    public function probeCache(): self
    {
        if (!getenv('REDIS_HOST') || !class_exists(\Redis::class)) {
            return $this->add('cache', 'skipped');
        }
        try {
            $r = new \Redis();
            $r->connect(getenv('REDIS_HOST'), (int) (getenv('REDIS_PORT') ?: 6379), 5.0);
            $db = (int) (getenv('REDIS_DB') ?: 0);
            $r->select($db);
            // Write and read back: connecting proves less than it looks like,
            // because a wrong logical database still connects.
            $r->set('ssmd:demo', 'ok', 30);
            $got = $r->get('ssmd:demo');
            return $this->add('cache', sprintf('db%d %s', $db, $got === 'ok' ? 'ok' : 'FAILED'));
        } catch (\Throwable $e) {
            return $this->add('cache', 'FAILED: ' . $e->getMessage());
        }
    }

    public function probeMail(): self
    {
        $host = getenv('MAIL_HOST');
        if (!$host) {
            return $this->add('mail', 'skipped');
        }
        $fp = @fsockopen($host, (int) (getenv('MAIL_PORT') ?: 1025), $errno, $errstr, 5);
        if ($fp === false) {
            return $this->add('mail', 'FAILED: ' . $errstr);
        }
        fclose($fp);
        return $this->add('mail', 'ok');
    }

    public function probeStorage(): self
    {
        $ep = getenv('S3_ENDPOINT');
        if (!$ep) {
            return $this->add('storage', 'skipped');
        }
        // MinIO answers /minio/health/live without credentials, which keeps this
        // probe from needing an S3 client just to say "reachable".
        $ctx = stream_context_create(['http' => ['timeout' => 5, 'ignore_errors' => true]]);
        $ok = @file_get_contents(rtrim($ep, '/') . '/minio/health/live', false, $ctx);
        return $this->add('storage', $ok !== false ? 'ok' : 'FAILED');
    }

    private function add(string $k, string $v): self
    {
        $this->lines[] = $k . '=' . $v;
        return $this;
    }

    public function render(): string
    {
        return implode("\n", $this->lines) . "\n";
    }

    public static function all(string $framework): string
    {
        return (new self($framework))
            ->probeDatabase()->probeCache()->probeMail()->probeStorage()->render();
    }
}
