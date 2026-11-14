<?php

// Executed by docker/entrypoint.sh through `php artisan tinker --execute`.
// It is intentionally idempotent: once any user exists nothing happens.

$email = trim((string) getenv('PICSTOME_ADMIN_EMAIL'));

if ($email === '') {
    fwrite(STDERR, "[picstome] PICSTOME_ADMIN_EMAIL is empty; skipping admin bootstrap.\n");

    return;
}

if (\App\Models\User::query()->exists()) {
    return;
}

$password = (string) getenv('PICSTOME_ADMIN_PASSWORD');

if ($password === '') {
    fwrite(STDERR, "[picstome] PICSTOME_ADMIN_PASSWORD is empty; skipping admin bootstrap.\n");

    return;
}

$name = trim((string) (getenv('PICSTOME_ADMIN_NAME') ?: 'Picstome Admin'));

$handle = (new \App\Services\HandleGenerationService)->generateUniqueHandle($name);

if ($handle === '') {
    $handle = 'studio';
}

$user = new \App\Models\User;
$user->forceFill([
    'name' => $name,
    'email' => $email,
    'password' => $password,
    'email_verified_at' => now(),
])->save();

// Self-hosted installs are not tied to Stripe, so the account is created with
// unlimited storage, contracts and invoices instead of the hosted free plan.
$team = $user->ownedTeams()->create([
    'name' => $name."'s Studio",
    'handle' => $handle,
    'personal_team' => true,
    'custom_storage_limit' => null,
    'monthly_contract_limit' => null,
    'monthly_invoice_limit' => null,
    'lifetime_at' => now(),
]);

$user->switchTeam($team);

fwrite(STDOUT, "[picstome] Created admin account {$email} with studio @{$handle}.\n");
