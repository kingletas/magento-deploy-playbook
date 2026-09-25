#!/usr/bin/env bash
# summary: code ahead of the schema fails; a schema ahead of the code does not
#
# P0-2. Puts the store into each mismatch on purpose and watches what a real
# request does.
#
# Falsifiers:
#   F2a  code selecting a missing column does not fail with an exception
#   F2b  with the database carrying a column the code no longer declares, the
#        home page, a product page, an admin login or a guest REST order fails
#   F2c  while the database is ahead, DbStatusValidator or ConfigChangeDetector
#        blocks a request. Each guard is first made to fire on purpose, so its
#        silence later means something
#   F2d  a FrontController plugin adds a check of its own (listed for review)
#
# Also recorded: what setup:db:status says while the database is ahead, with
# the old whitelist and with the new whitelist left in place; and what happens
# when the thing that is ahead is a module's setup_version rather than a column.
#
# Changes the store: creates one product, alters the fixture module and
# app/etc/config.php, runs setup:upgrade, and restores snapshot 'fixture' and
# config.php when it finishes.

# shellcheck source=/dev/null  # ZDT_PROOF_DIR is set by bin/zdt-proof at run time
source "$ZDT_PROOF_DIR/lib.sh"

OUT=$(outdir p0-2)
CONFIG_PHP="$HOST_ROOT/app/etc/config.php"

stage
ensure_fixture
reset_fixture
cp "$CONFIG_PHP" "$OUT/config.php.orig"
restore_config() { cp "$OUT/config.php.orig" "$CONFIG_PHP"; }

step "Setting up: one product, and a probe that works"
# ZDT_PRODUCT_SKU and ZDT_PRODUCT_PATH name an existing in-stock simple product
# instead, for a store where saving a product through the API is slow.
PRODUCT_SKU="${ZDT_PRODUCT_SKU:-zdt-simple}"
PRODUCT_PATH="${ZDT_PRODUCT_PATH:-zdt-simple.html}"
if [[ -z ${ZDT_PRODUCT_SKU:-} ]]; then
    mphp local.d/zdt-proof/php/catalogue.php
else
    note "using the store's own product $PRODUCT_SKU at /$PRODUCT_PATH"
fi
sql "INSERT INTO zdt_proof_item (sku, qty) VALUES ('zdt-row', 1)"
magento indexer:reindex >/dev/null 2>&1 || note "reindex reported a problem; continuing"
magento cache:flush >/dev/null
# A store just switched to developer mode generates classes on its first
# requests, which can take minutes; these warm it outside the checks.
for path in / zdtproof/probe/index "$PRODUCT_PATH"; do
    curl -s -o /dev/null --max-time 900 "$(bust "$BASE_URL/${path#/}")" || note "warm-up request to /${path#/} did not finish"
done
code=$(http "$(bust "$BASE_URL/zdtproof/probe/index")")
if [[ $code == 200 ]]; then
    pass "control: the probe answers 200 when code and schema agree"
else
    fail "control: the probe answers $code with nothing mismatched, so the rest of this proof means nothing"
fi

step "F2a: code ahead of the schema"
fixture_state probe-ahead
code=$(http "$(bust "$BASE_URL/zdtproof/probe/index")")
cp "$LAST_BODY" "$OUT/f2a-body.html"
echo "status=$code"
grep -o "Unknown column '[^']*'" "$OUT/f2a-body.html" | head -1 || true
if [[ $code -ge 500 ]] && grep -q "Unknown column" "$OUT/f2a-body.html"; then
    pass "F2a code selecting a missing column answers $code with Unknown column"
else
    fail "F2a code selecting a missing column answered $code"
fi
fixture_state
code=$(http "$(bust "$BASE_URL/zdtproof/probe/index")")
if [[ $code == 200 ]]; then
    pass "F2a fix: reverting the code brings the probe back to 200"
else
    fail "F2a fix: the probe still answers $code after reverting"
fi

step "Expanding: add the column, and code that reads it"
fixture_state add-column probe-ahead
magento setup:upgrade --keep-generated >"$OUT/expand-upgrade.out" 2>&1 || fail "setup:upgrade failed while expanding; see expand-upgrade.out"
code=$(http "$(bust "$BASE_URL/zdtproof/probe/index")")
if [[ $code == 200 ]] && grep -q '"colour"' "$LAST_BODY"; then
    pass "expanded: the new code reads the new column"
else
    fail "expanded: probe answers $code: $(head -c 200 "$LAST_BODY")"
fi

step "F2b: the old release on the new schema"
fixture_state
magento cache:flush >/dev/null
echo "column_in_database=$(sql "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='zdt_proof_item' AND COLUMN_NAME='colour'" | tail -1)"
home=$(http "$(bust "$BASE_URL/")")
product=$(http "$(bust "$BASE_URL/$PRODUCT_PATH")")
probe=$(http "$(bust "$BASE_URL/zdtproof/probe/index")")
echo "home=$home product=$product probe=$probe"
if [[ $home == 200 ]]; then
    pass "F2b home page 200 with the database ahead"
else
    fail "F2b home page answered $home with the database ahead"
fi
if [[ $product == 200 ]]; then
    pass "F2b product page 200 with the database ahead"
else
    fail "F2b product page answered $product with the database ahead"
fi
if [[ $probe == 200 ]]; then
    pass "F2b the old probe code still reads its own columns"
else
    fail "F2b the old probe answered $probe"
fi

# shellcheck disable=SC2154  # envfile is set by lib.sh
admin_user=$(sed -n "s/^MAGENTO_ADMIN_USER=//p" "$envfile"); admin_user="${admin_user:-admin}"
admin_password=$(sed -n "s/^MAGENTO_ADMIN_PASSWORD=//p" "$envfile")
# A site with no admin password in its settings gets a throwaway admin, in a
# database this proof restores from a snapshot when it finishes.
if [[ -z $admin_password ]]; then
    admin_user=zdtproof
    admin_password="Zdt$(head -c 18 /dev/urandom | od -An -tx1 | tr -d ' \n')1"
    magento admin:user:create --admin-user="$admin_user" --admin-password="$admin_password" \
        --admin-email=zdtproof@example.test --admin-firstname=Zdt --admin-lastname=Proof >/dev/null
    note "no admin password in the site settings; created a throwaway admin for this run"
fi
admin_uri=$(sed -n 's/^MAGENTO_ADMIN_URI=//p' "$envfile")
jar=$(mktemp)
http -c "$jar" -b "$jar" "$BASE_URL/${admin_uri:-admin}/" >/dev/null
form_key=$(grep -o 'name="form_key" type="hidden" value="[^"]*"' "$LAST_BODY" | sed 's/.*value="//; s/"$//' | head -1)
# The password is read from the settings file by curl's own config parser, so it never appears on a command line.
login=$(printf 'data-urlencode = "login[password]=%s"\n' "$admin_password" |
    curl -s -o "$LAST_BODY" -w '%{http_code} %{url_effective}' --max-time 120 -c "$jar" -b "$jar" -L -K - --data-urlencode "login[username]=$admin_user" --data-urlencode "form_key=$form_key" "$BASE_URL/${admin_uri:-admin}/")
rm -f "$jar"
landed=$(grep -o '<title>[^<]*</title>' "$LAST_BODY" | head -1)
echo "admin_login=$login $landed"
if [[ $login == "200 "* && $login != */admin/ && $login != */admin ]] && ! grep -q 'name="login\[password\]"' "$LAST_BODY"; then
    pass "F2b admin login gets past the login form to ${login#200 } with the database ahead"
else
    fail "F2b admin login answered $login ($landed)"
fi

rest="$BASE_URL/rest/default/V1"
address='{"firstname":"Test","lastname":"Buyer","street":["1 Example Street"],"city":"Exampleton","region":"Texas","region_id":57,"postcode":"78701","country_id":"US","telephone":"5550100","email":"buyer@example.test"}'
cart=$(curl -s -X POST -H 'Content-Type: application/json' "$rest/guest-carts" | tr -d '"')
curl -s -X POST -H 'Content-Type: application/json' "$rest/guest-carts/$cart/items" \
    -d "{\"cartItem\":{\"sku\":\"$PRODUCT_SKU\",\"qty\":1,\"quote_id\":\"$cart\"}}" >"$OUT/f2b-item.json"
curl -s -X POST -H 'Content-Type: application/json' "$rest/guest-carts/$cart/shipping-information" \
    -d "{\"addressInformation\":{\"shipping_address\":$address,\"billing_address\":$address,\"shipping_carrier_code\":\"flatrate\",\"shipping_method_code\":\"flatrate\"}}" >"$OUT/f2b-shipping.json"
order=$(curl -s -X POST -H 'Content-Type: application/json' "$rest/guest-carts/$cart/payment-information" \
    -d "{\"email\":\"buyer@example.test\",\"paymentMethod\":{\"method\":\"checkmo\"},\"billingAddress\":$address}")
echo "order=$order"
if [[ $order =~ ^\"?[0-9]+\"?$ ]]; then
    pass "F2b guest order $order placed through REST with the database ahead"
else
    fail "F2b guest order failed: $order"
fi

step "F2c: setup:db:status while the database is ahead"
magento setup:db:status >"$OUT/f2c-status-old-whitelist.out" 2>&1 && st=0 || st=$?
echo "old whitelist: exit=$st $(tr '\n' ' ' <"$OUT/f2c-status-old-whitelist.out")"
fixture_state whitelist-colour
magento setup:db:status >"$OUT/f2c-status-new-whitelist.out" 2>&1 && st2=0 || st2=$?
echo "new whitelist: exit=$st2 $(tr '\n' ' ' <"$OUT/f2c-status-new-whitelist.out")"
rm -f "$HOST_ROOT/var/log/dry-run-installation.log"
magento setup:upgrade --dry-run=1 --keep-generated >/dev/null 2>&1 || true
cp "$HOST_ROOT/var/log/dry-run-installation.log" "$OUT/f2c-dry-run-new-whitelist.sql" 2>/dev/null || : >"$OUT/f2c-dry-run-new-whitelist.sql"
echo "dry run with the new whitelist: $(tr '\n' ' ' <"$OUT/f2c-dry-run-new-whitelist.sql")"
if [[ $st == 0 ]]; then
    note "old release's whitelist: setup:db:status says up to date"
else
    note "old release's whitelist: setup:db:status exits $st"
fi
if [[ $st2 != 0 ]]; then
    note "code reverted with the new whitelist left in: setup:db:status exits $st2, so a gate on it would run setup:upgrade"
else
    note "new whitelist left in: setup:db:status still exits 0"
fi
fixture_state

step "F2c: make DbStatusValidator fire on purpose, then watch it stay quiet"
fixture_state bump-version
magento cache:clean config >/dev/null
code=$(http "$(bust "$BASE_URL/")")
if grep -q "upgrade your database" "$LAST_BODY"; then
    pass "F2c negative control: a setup_version ahead of the database blocks the storefront ($code, 'Please upgrade your database')"
else
    fail "F2c negative control: DbStatusValidator did not fire ($code)"
fi
fixture_state
magento cache:clean config >/dev/null
code=$(http "$(bust "$BASE_URL/")")
if [[ $code == 200 ]]; then
    pass "F2c DbStatusValidator is quiet with the column ahead and versions equal"
else
    fail "F2c home answered $code with only the column ahead"
fi

step "F2c: make ConfigChangeDetector fire on purpose, then watch it stay quiet"
# shellcheck disable=SC2016  # PHP source: PHP expands these, not the shell
mphp -r '
    $c = require "app/etc/config.php";
    $c["system"]["default"]["general"]["locale"]["code"] = "en_GB";
    file_put_contents("app/etc/config.php", "<?php\nreturn " . var_export($c, true) . ";\n");
'
settle
code=$(http "$(bust "$BASE_URL/")")
if grep -q "configuration file has changed" "$LAST_BODY"; then
    pass "F2c negative control: an edited config.php blocks the storefront ($code, 'The configuration file has changed')"
else
    fail "F2c negative control: ConfigChangeDetector did not fire ($code)"
fi
restore_config
settle
code=$(http "$(bust "$BASE_URL/")")
if [[ $code == 200 ]]; then
    pass "F2c ConfigChangeDetector is quiet with the column ahead"
else
    fail "F2c home answered $code after config.php was put back"
fi

step "Version ahead rather than column ahead: the other branch of DbStatusValidator"
fixture_state bump-version
magento setup:upgrade --keep-generated >"$OUT/version-upgrade.out" 2>&1 || fail "setup:upgrade failed for the version bump"
echo "setup_module: $(sql "SELECT schema_version, data_version FROM setup_module WHERE module='Kingletas_ZdtProof'" | tail -1)"
code=$(http "$(bust "$BASE_URL/")")
echo "new code on new version: $code"
fixture_state
code=$(http "$(bust "$BASE_URL/")")
echo "old code, cache still holding db_is_up_to_date: $code"
[[ $code == 200 ]] && note "while the config cache holds db_is_up_to_date, old code on a newer setup_version is not checked at all"
magento cache:clean config >/dev/null
code=$(http "$(bust "$BASE_URL/")")
if grep -q "update your modules" "$LAST_BODY"; then
    fail "database ahead is not harmless when a release bumps setup_version: old code answers $code, 'Please update your modules'"
else
    pass "old code on a newer setup_version answers $code with no DbStatusValidator error"
fi

step "F2d: the plugins on FrontController"
magento dev:di:info 'Magento\Framework\App\FrontController' >"$OUT/f2d-di-info.txt" 2>&1 || true
magento dev:di:info 'Magento\Framework\App\FrontControllerInterface' >>"$OUT/f2d-di-info.txt" 2>&1 || true
sed -n '/Plugins/,$p' "$OUT/f2d-di-info.txt"
note "F2d the plugin list is in f2d-di-info.txt and is judged by reading each one"

step "Restoring snapshot 'fixture' and config.php"
restore_config
reset_fixture
finish
