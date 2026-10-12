// Turns the output of `firebase apps:sdkconfig <platform> <appId> --json` for the
// web, Android and iOS apps into the files the app and API read:
//
//   config/firebase.local.json                  --dart-define-from-file for Flutter,
//                                               FIREBASE_PROJECT_ID for the API
//   apps/mobile/ios/Flutter/Firebase.xcconfig    FIREBASE_IOS_URL_SCHEME for Info.plist
//
// Usage: node scripts/firebase_app_config.mjs <web.json> <android.json> <ios.json> <androidAppId> <iosAppId>
// Called by scripts/firebase-setup.sh; both outputs are git-ignored.
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const [webFile, androidFile, iosFile, androidAppId, iosAppId] = process.argv.slice(2);
if (!iosAppId) {
  console.error("usage: firebase_app_config.mjs <web.json> <android.json> <ios.json> <androidAppId> <iosAppId>");
  process.exit(2);
}

function result(file) {
  const out = JSON.parse(readFileSync(file, "utf8"));
  if (out.status !== "success") throw new Error(`${file}: ${out.error ?? "sdkconfig failed"}`);
  return out.result;
}

// Web: the CLI returns the config object directly.
const web = result(webFile).sdkConfig;
if (!web?.apiKey || !web?.appId) throw new Error("web config has no apiKey/appId");

// Android: google-services.json; pick the client for our app id.
const services = JSON.parse(result(androidFile).fileContents);
const client = services.client.find((c) => c.client_info.mobilesdk_app_id === androidAppId);
if (!client) throw new Error(`google-services.json has no client ${androidAppId}`);
const androidKey = client.api_key?.[0]?.current_key;

// iOS: GoogleService-Info.plist, flat <key>/<string> pairs.
const plist = result(iosFile).fileContents;
const ios = Object.fromEntries(
  [...plist.matchAll(/<key>([^<]+)<\/key>\s*<string>([^<]*)<\/string>/g)].map((m) => [m[1], m[2]]),
);
if (ios.GOOGLE_APP_ID !== iosAppId) throw new Error(`GoogleService-Info.plist is for ${ios.GOOGLE_APP_ID}, not ${iosAppId}`);

const defines = {
  FIREBASE_PROJECT_ID: web.projectId,
  FIREBASE_MESSAGING_SENDER_ID: web.messagingSenderId,
  FIREBASE_AUTH_DOMAIN: web.authDomain,
  FIREBASE_STORAGE_BUCKET: web.storageBucket ?? "",
  FIREBASE_APP_ID_WEB: web.appId,
  FIREBASE_API_KEY_WEB: web.apiKey,
  FIREBASE_APP_ID_ANDROID: androidAppId,
  FIREBASE_API_KEY_ANDROID: androidKey ?? web.apiKey,
  FIREBASE_APP_ID_IOS: iosAppId,
  FIREBASE_API_KEY_IOS: ios.API_KEY ?? web.apiKey,
  FIREBASE_IOS_BUNDLE_ID: ios.BUNDLE_ID ?? "",
};
for (const [k, v] of Object.entries(defines)) {
  if (v === undefined) throw new Error(`missing ${k}`);
}

mkdirSync(join(root, "config"), { recursive: true });
writeFileSync(join(root, "config/firebase.local.json"), JSON.stringify(defines, null, 2) + "\n");

// Firebase's provider sign-in on iOS returns to the app through a URL scheme made
// from the encoded app id ("1:123:ios:abc" becomes "app-1-123-ios-abc").
const scheme = "app-" + iosAppId.replaceAll(":", "-");
writeFileSync(
  join(root, "apps/mobile/ios/Flutter/Firebase.xcconfig"),
  `// Written by scripts/firebase-setup.sh. Do not commit.\nFIREBASE_IOS_URL_SCHEME=${scheme}\n`,
);

console.log(`Wrote config/firebase.local.json (project ${defines.FIREBASE_PROJECT_ID}) and ios/Flutter/Firebase.xcconfig`);
