const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '../..');
const api = fs.readFileSync(path.join(root, 'backend/api-core.js'), 'utf8');
const page = fs.readFileSync(path.join(root, 'frontend/src/features/account/FundPasswordPage.tsx'), 'utf8');
const securityPage = fs.readFileSync(path.join(root, 'frontend/src/features/account/AccountSecurityPage.tsx'), 'utf8');
const twoFactorCard = fs.readFileSync(path.join(root, 'frontend/src/features/account/TwoFactorCard.tsx'), 'utf8');

test('fund-password changes do not require 2FA; use password or recent OAuth sign-in proof', () => {
  const start = api.indexOf("if (path === 'settings/fundpwd' && method === 'POST')");
  const end = api.indexOf("// ---------- POST /api/settings/2fa", start);
  assert.ok(start >= 0 && end > start, 'fund-password route exists');
  const route = api.slice(start, end);
  assert.match(route, /hasLocalPassword/);
  assert.match(route, /verifyBtcboxLoginPassword\(user, currentPassword\)/);
  assert.match(route, /RECENT_REAUTH_REQUIRED/);
  assert.match(route, /5 \* 60 \* 1000/);
  assert.doesNotMatch(route, /TWOFA_REQUIRED|TWOFA_INVALID|twofa_code|user\.twofa_enabled/);
  assert.match(api, /fundpwd_reauth_mode: user\.login_password_hash && user\.login_password_salt \? 'password' : 'recent_signin'/);
});

test('fund-password page does not gate OAuth users or render a mandatory authenticator field', () => {
  assert.match(page, /const requiresCurrentPassword = account\?\.has_login_password !== false/);
  assert.match(page, /requiresCurrentPassword && <label/);
  assert.doesNotMatch(page, /requiresTwoFactor|twoFactorCode|Authenticator code|enable two-factor authentication before setting/i);
});

test('withdrawal only requests a 2FA code when the account has voluntarily enabled it', () => {
  const pages = fs.readFileSync(path.join(root, 'frontend/src/features/pages/Pages.tsx'), 'utf8');
  assert.match(pages, /\(\!account\?\.twofa_enabled\|\|\/\^\\d\{6\}\$\/\.test\(twofaCode\)\)/);
  assert.match(pages, /account\?\.twofa_enabled\?<label[\s\S]*Two-factor code/);
  const start = api.indexOf("if (path === 'withdraw' && method === 'POST')");
  assert.ok(start >= 0, 'withdrawal API route exists');
  const route = api.slice(start, start + 14000);
  assert.match(route, /if \(user\.twofa_enabled && !\/\^\\d\{6\}\$\//);
});

test('2FA enrollment uses BTCBOX local credentials for hybrid accounts, not provider presence', () => {
  const start = api.indexOf("if (path === '2fa/enable' && method === 'POST')");
  const end = api.indexOf("// ---------- POST /api/2fa/confirm", start);
  assert.ok(start >= 0 && end > start, '2FA enrollment route exists');
  const route = api.slice(start, end);
  assert.match(route, /login_password_hash && user\.login_password_salt && user\.login_password_algo === 'pbkdf2-sha256-600000'/);
  assert.match(route, /verifyBtcboxLoginPassword\(user, currentPassword\)/);
  assert.match(route, /sessionAge < 0 \|\| sessionAge > 5 \* 60 \* 1000/);
  assert.doesNotMatch(route, /user\.auth_providers/);
});

test('account security opens the real 2FA manager and refreshes account state after changes', () => {
  assert.match(securityPage, /import \{ TwoFactorCard \} from "\.\/TwoFactorCard"/);
  assert.match(securityPage, /<TwoFactorCard account=\{account\} onChanged=\{\(\) => \{ void refreshAccount\(\); \}\} \/>/);
  assert.match(securityPage, /const refreshAccount = useCallback/);
  assert.doesNotMatch(securityPage, /Enable two-factor authentication to protect your account\.\)\}\s*<Button[^>]*>\{t\("Close"\)\}/);
});

test('email sign-in password is not represented as a BTCBOX local login password', () => {
  assert.match(securityPage, /Email sign-in password/);
  assert.match(securityPage, /does not create or change a BTCBOX username password/);
  assert.doesNotMatch(securityPage, /setAccount\(\(current\) => current \? \{ \.\.\.current, has_login_password: true \}/);
});

test('2FA enrollment password prompt matches the account credential type and 2FA remains optional', () => {
  assert.match(twoFactorCard, /account\?\.has_login_password === true/);
  assert.match(twoFactorCard, /No additional password is required for OAuth-only accounts/);
  assert.match(twoFactorCard, /Two-factor authentication is optional/);
});

test('withdrawal retry copy does not imply 2FA is mandatory', () => {
  const pages = fs.readFileSync(path.join(root, 'frontend/src/features/pages/Pages.tsx'), 'utf8');
  assert.match(pages, /if 2FA is enabled, your authenticator code/);
});

test('fund-password page explains that local-password confirmation does not sign the user out', () => {
  assert.match(page, /You do not need to sign out or sign in again/);
  assert.match(page, /a recent sign-in may be required/);
  assert.match(page, /Confirm current login password/);
});

test('withdrawal customer copy does not expose staff review or manual payout workflow', () => {
  const pages = fs.readFileSync(path.join(root, 'frontend/src/features/pages/Pages.tsx'), 'utf8');
  assert.match(pages, /Choose a saved address and enter the amount you want to withdraw/);
  assert.match(pages, /Withdrawal request submitted\. You can track its progress in withdrawal history/);
  assert.match(pages, /t\("Submit withdrawal"\)/);
  assert.doesNotMatch(pages, /Submit for staff review|Withdrawal submitted for staff review|staff review and manually pay approved requests/);
});

test('account password capability flag requires the complete supported BTCBOX credential tuple', () => {
  assert.match(api, /has_login_password: !!\(user\.login_password_hash && user\.login_password_salt && user\.login_password_algo === 'pbkdf2-sha256-600000'\)/);
});
