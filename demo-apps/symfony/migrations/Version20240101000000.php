<?php

declare(strict_types=1);

namespace App\Migrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\Migrations\AbstractMigration;

/**
 * One migration, so `dx db:migrate` has something to apply and each worktree
 * instance builds a schema in its own database.
 */
final class Version20240101000000 extends AbstractMigration
{
    public function getDescription(): string
    {
        return 'Create the demo_notes table';
    }

    public function up(Schema $schema): void
    {
        $table = $schema->createTable('demo_notes');
        $table->addColumn('id', 'integer', ['autoincrement' => true]);
        $table->addColumn('body', 'string', ['length' => 255]);
        $table->setPrimaryKey(['id']);
    }

    public function down(Schema $schema): void
    {
        $schema->dropTable('demo_notes');
    }
}
