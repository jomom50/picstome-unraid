<?php

// Executed by docker/entrypoint.sh through `php artisan tinker --execute`.
//
// Two jobs, both idempotent:
//
// 1. Create the admin account named by PICSTOME_ADMIN_EMAIL when it is missing.
// 2. When that account already exists, make sure a self-hosted install is not
//    stuck on Picstome's hosted free plan. An account registered through the
//    web form gets config('picstome.personal_team_storage_limit') (1 GB) plus
//    one contract and one invoice per month, and no lifetime_at, which shows
//    the "your storage is almost full" banner and the subscribe prompts.
//    The operator's own account should not hit a plan they are hosting.

$email = trim((string) getenv('PICSTOME_ADMIN_EMAIL'));

if ($email === '') {
    fwrite(STDERR, "[picstome] PICSTOME_ADMIN_EMAIL is empty; skipping admin bootstrap.\n");

    return;
}

$unlimited = filter_var(
    getenv('PICSTOME_ADMIN_UNLIMITED') ?: 'true',
    FILTER_VALIDATE_BOOLEAN,
);

$user = \App\Models\User::query()->where('email', $email)->first();

if (! $user) {
    $password = (string) getenv('PICSTOME_ADMIN_PASSWORD');
    $generated = false;

    if ($password === '') {
        $password = bin2hex(random_bytes(8));
        $generated = true;
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

    // Self-hosted installs are not tied to Stripe, so the account is created
    // with unlimited storage, contracts and invoices instead of the free plan.
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

    if ($generated) {
        $path = '/data/initial-admin-password.txt';
        @file_put_contents($path, $password."\n");
        @chmod($path, 0600);

        fwrite(STDOUT, "[picstome] No admin password was set; wrote one to {$path}.\n");
    }

    return;
}

// The account exists: it was probably registered in the web UI, so it carries
// the free-plan limits unless the operator already raised them.
if ($user->email_verified_at === null) {
    $user->forceFill(['email_verified_at' => now()])->save();
}

if (! $unlimited) {
    return;
}

$team = $user->personalTeam() ?: $user->ownedTeams()->first();

if (! $team) {
    return;
}

$changes = [];

if ($team->custom_storage_limit !== null) {
    $changes['custom_storage_limit'] = null;
}

if ($team->monthly_contract_limit !== null) {
    $changes['monthly_contract_limit'] = null;
}

if ($team->monthly_invoice_limit !== null) {
    $changes['monthly_invoice_limit'] = null;
}

if ($team->lifetime_at === null) {
    $changes['lifetime_at'] = now();
}

if ($changes === []) {
    return;
}

$team->forceFill($changes)->save();

fwrite(STDOUT, "[picstome] Removed the hosted plan limits from @{$team->handle} for admin {$email}.\n");
