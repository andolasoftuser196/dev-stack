<?php
declare(strict_types=1);

namespace App\Test\TestCase;

use PHPUnit\Framework\TestCase;

final class StatusTest extends TestCase
{
    public function testRunsAgainstADisposableDatabase(): void
    {
        $db = getenv('DB_DATABASE');
        if ($db === false || $db === '') {
            $this->markTestSkipped('no database configured');
        }
        $this->assertMatchesRegularExpression('/(_test|_sandbox)$/', $db);
    }
}
