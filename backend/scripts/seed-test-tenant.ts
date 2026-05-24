// Seed a test tenant (auth user + org + membership + sample project) so
// /v1/scan can be smoke-tested end-to-end. Idempotent: re-running re-uses
// the existing rows. Reads SUPABASE_SERVICE_ROLE_KEY and DATABASE_URL from
// the environment — invoke via: npm run seed

import { createClient } from '@supabase/supabase-js';
import { PrismaClient } from '@prisma/client';

const EMAIL = process.env.SEED_USER_EMAIL ?? 'seed-owner@example.com';
const PASSWORD = process.env.SEED_USER_PASSWORD ?? 'SeedOwner!Pass123';
const ORG_NAME = process.env.SEED_ORG_NAME ?? 'Seed Test Org';
const ORG_COMPANY_CODE = process.env.SEED_COMPANY_CODE ?? 'SEED-CO';
const PROJECT_NAME = process.env.SEED_PROJECT_NAME ?? 'Project Alpha';
const PROJECT_ADDRESS =
  process.env.SEED_PROJECT_ADDRESS ?? 'Rothschild 1, Tel Aviv';

function resolveSupabaseUrl(): string {
  if (process.env.SUPABASE_URL) return process.env.SUPABASE_URL;
  const db = process.env.DATABASE_URL;
  if (!db) {
    throw new Error('Neither SUPABASE_URL nor DATABASE_URL is set');
  }
  const m = db.match(/postgres\.([a-z0-9]{20})/);
  if (!m) {
    throw new Error(
      'Could not derive Supabase project ref from DATABASE_URL — set SUPABASE_URL explicitly',
    );
  }
  return `https://${m[1]}.supabase.co`;
}

async function ensureAuthUser(
  supabase: ReturnType<typeof createClient>,
): Promise<string> {
  // listUsers paginates; for a dev project the first page is enough.
  const { data: list, error: listErr } = await supabase.auth.admin.listUsers({
    page: 1,
    perPage: 200,
  });
  if (listErr) throw listErr;
  const existing = list.users.find((u) => u.email === EMAIL);
  if (existing) {
    console.log(`auth.users: re-using existing user for ${EMAIL}`);
    return existing.id;
  }

  const { data, error } = await supabase.auth.admin.createUser({
    email: EMAIL,
    password: PASSWORD,
    email_confirm: true,
    user_metadata: { full_name: 'Seed Owner' },
  });
  if (error) throw error;
  if (!data.user) throw new Error('createUser returned no user');
  console.log(`auth.users: created ${EMAIL}`);
  return data.user.id;
}

async function waitForProfile(
  prisma: PrismaClient,
  userId: string,
): Promise<{ id: string; defaultOrgId: string | null } | null> {
  // The on_auth_user_created trigger inserts into public.users — but it
  // may lag a moment after createUser returns.
  for (let i = 0; i < 10; i++) {
    const row = await prisma.user.findUnique({
      where: { id: userId },
      select: { id: true, defaultOrgId: true },
    });
    if (row) return row;
    await new Promise((r) => setTimeout(r, 200));
  }
  return null;
}

async function main(): Promise<void> {
  const supabaseUrl = resolveSupabaseUrl();
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!serviceKey) {
    throw new Error('SUPABASE_SERVICE_ROLE_KEY is not set');
  }

  const supabase = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const prisma = new PrismaClient();

  try {
    const userId = await ensureAuthUser(supabase);

    let profile = await waitForProfile(prisma, userId);
    if (!profile) {
      // Trigger didn't fire — insert manually as a fallback.
      profile = await prisma.user.create({
        data: { id: userId, email: EMAIL, displayName: 'Seed Owner' },
        select: { id: true, defaultOrgId: true },
      });
      console.log('public.users: created manually (trigger did not fire)');
    } else {
      console.log('public.users: profile present');
    }

    let org = await prisma.organization.findFirst({
      where: { displayName: ORG_NAME, deletedAt: null },
      select: { id: true, companyCode: true },
    });
    if (!org) {
      org = await prisma.organization.create({
        data: {
          kind: 'individual',
          displayName: ORG_NAME,
          companyCode: ORG_COMPANY_CODE,
        },
        select: { id: true, companyCode: true },
      });
      console.log(`organizations: created ${ORG_NAME} (${ORG_COMPANY_CODE})`);
    } else {
      if (org.companyCode !== ORG_COMPANY_CODE) {
        await prisma.organization.update({
          where: { id: org.id },
          data: { companyCode: ORG_COMPANY_CODE },
        });
        console.log(
          `organizations: updated company_code to ${ORG_COMPANY_CODE}`,
        );
      } else {
        console.log(`organizations: re-using ${ORG_NAME} (${ORG_COMPANY_CODE})`);
      }
    }

    await prisma.membership.upsert({
      where: { userId_orgId: { userId, orgId: org.id } },
      create: { userId, orgId: org.id, role: 'owner', status: 'active' },
      update: { role: 'owner', status: 'active' },
    });
    console.log('memberships: owner role ensured');

    if (!profile.defaultOrgId) {
      await prisma.user.update({
        where: { id: userId },
        data: { defaultOrgId: org.id },
      });
      console.log('public.users: default_org_id set');
    }

    await prisma.project.upsert({
      where: { orgId_name: { orgId: org.id, name: PROJECT_NAME } },
      create: {
        orgId: org.id,
        name: PROJECT_NAME,
        address: PROJECT_ADDRESS,
      },
      update: { address: PROJECT_ADDRESS, active: true },
    });
    console.log(`projects: ${PROJECT_NAME} ensured`);

    console.log('');
    console.log('=== seed complete ===');
    console.log(`ORG_ID=${org.id}`);
    console.log(`USER_ID=${userId}`);
    console.log(`COMPANY_CODE=${ORG_COMPANY_CODE}`);
    console.log(`PROJECT_NAME=${PROJECT_NAME}`);
    console.log('');
    console.log('Smoke test (two-step flow):');
    console.log('');
    console.log('1) Exchange company_code for a session token:');
    console.log('curl -X POST http://localhost:8080/v1/sessions/exchange \\');
    console.log("  -H 'content-type: application/json' \\");
    console.log(
      "  -d '" +
        JSON.stringify({
          company_code: ORG_COMPANY_CODE,
          device_id: 'dev-machine',
        }) +
        "'",
    );
    console.log('');
    console.log('2) Call /v1/scan with the returned token:');
    console.log('curl -X POST http://localhost:8080/v1/scan \\');
    console.log("  -H 'content-type: application/json' \\");
    console.log("  -H 'authorization: Bearer <token-from-step-1>' \\");
    console.log(
      "  -d '" +
        JSON.stringify({
          company_code: ORG_COMPANY_CODE,
          projects: [{ name: PROJECT_NAME, address: PROJECT_ADDRESS }],
          image: { mime_type: 'image/jpeg', data: '<base64>' },
        }) +
        "'",
    );
  } finally {
    await prisma.$disconnect();
  }
}

main().catch((e: unknown) => {
  console.error(e);
  process.exit(1);
});
