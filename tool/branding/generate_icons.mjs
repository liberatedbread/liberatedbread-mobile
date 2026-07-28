#!/usr/bin/env node
// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Regenerates every platform app icon from a single piece of artwork plus the
// palette in brand.json, and re-syncs the Android/web chrome colours that have
// to repeat the brand background outside of Dart.
//
//   cd tool/branding && npm install && npm run icons
//
// Artwork source, highest priority first:
//   1. app_icon_mascot.png  — square, transparent; drop one in to replace the
//                             logo without touching any vector
//   2. app_icon_mascot.svg  — the checked-in vector master
//
// The artwork is mascot-only on transparency; this script owns the background,
// the per-platform padding, and the platform-specific shaping rules (iOS must
// be opaque, Android adaptive foregrounds must sit inside the 66% safe zone,
// maskable web icons inside the 80% circle, macOS inside a squircle).
//
// Icons are committed, so CI never runs this — it is a local authoring tool.
import sharp from 'sharp';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '../..');
const p = (...parts) => path.join(ROOT, ...parts);

const brand = JSON.parse(fs.readFileSync(path.join(HERE, 'brand.json'), 'utf8'));
const BG = brand.teal;

// Master render size. Everything is downscaled from this one raster so SVG and
// PNG sources go through an identical path.
const MASTER = 1024;

// Fraction of the final canvas the mascot's (square, tight-cropped) box spans.
// These are the platform safe zones — see the header note.
const VARIANTS = {
  fullbleed: { bg: BG, content: 0.78 },
  maskable: { bg: BG, content: 0.56 },
  adaptiveFg: { bg: null, content: 0.61 },
  macos: { bg: BG, content: 0.645, squircle: true },
  // Android 13+ themed icons: a flat silhouette the launcher tints itself, so
  // it must be a single opaque colour on transparency — not the full-colour
  // artwork. Same safe zone as the adaptive foreground.
  monochrome: { bg: null, content: 0.61, silhouette: true },
};

function resolveSource() {
  const png = path.join(HERE, 'app_icon_mascot.png');
  const svg = path.join(HERE, 'app_icon_mascot.svg');
  if (fs.existsSync(png)) return { file: png, kind: 'png' };
  if (fs.existsSync(svg)) return { file: svg, kind: 'svg' };
  throw new Error('No app_icon_mascot.png or app_icon_mascot.svg in tool/branding.');
}

async function buildMaster() {
  const src = resolveSource();
  console.log(`artwork: ${path.relative(ROOT, src.file)}`);
  return sharp(src.file, { density: 600 })
    .resize(MASTER, MASTER, {
      fit: 'contain',
      background: { r: 0, g: 0, b: 0, alpha: 0 },
    })
    .png()
    .toBuffer();
}

function squircleCanvas(size) {
  // macOS Big Sur proportions: art sits in a rounded square inset from the
  // canvas, which is what gives macOS icons their consistent optical size.
  const inset = Math.round((size * 52) / 512);
  const side = size - inset * 2;
  const r = Math.round((size * 92) / 512);
  return Buffer.from(
    `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}">` +
      `<rect x="${inset}" y="${inset}" width="${side}" height="${side}" ` +
      `rx="${r}" ry="${r}" fill="${BG}"/></svg>`,
  );
}

async function render(master, size, variantName, dest, { opaque = false } = {}) {
  const v = VARIANTS[variantName];
  const inner = Math.max(1, Math.round(size * v.content));
  let art = await sharp(master).resize(inner, inner).png().toBuffer();

  if (v.silhouette) {
    // Flatten the artwork to a solid shape: 'dest-in' keeps the black square
    // only where the artwork is opaque, so the result is the mascot's outline
    // in one colour with its transparency intact.
    art = await sharp({
      create: { width: inner, height: inner, channels: 4, background: '#000000' },
    })
      .composite([{ input: art, blend: 'dest-in' }])
      .png()
      .toBuffer();
  }

  let base;
  if (v.squircle) {
    base = sharp(squircleCanvas(size));
  } else {
    base = sharp({
      create: {
        width: size,
        height: size,
        channels: 4,
        background: v.bg ?? { r: 0, g: 0, b: 0, alpha: 0 },
      },
    });
  }

  const composited = await base
    .composite([{ input: art, gravity: 'center' }])
    .png()
    .toBuffer();

  // Flatten in a second pass, not chained onto the composite above: sharp
  // applies flatten *before* composite in its fixed pipeline order, so chaining
  // would flatten the bare background and then layer the transparent art back
  // on top, leaving the alpha channel in place. The App Store rejects iOS icons
  // that have one, so this has to actually take effect.
  let out = sharp(composited);
  if (opaque) out = out.flatten({ background: BG }).removeAlpha();

  fs.mkdirSync(path.dirname(dest), { recursive: true });
  await out.png().toFile(dest);
}

// --- Platform size tables -------------------------------------------------

const IOS_DIR = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
const IOS = {
  'Icon-App-20x20@1x.png': 20, 'Icon-App-20x20@2x.png': 40, 'Icon-App-20x20@3x.png': 60,
  'Icon-App-29x29@1x.png': 29, 'Icon-App-29x29@2x.png': 58, 'Icon-App-29x29@3x.png': 87,
  'Icon-App-40x40@1x.png': 40, 'Icon-App-40x40@2x.png': 80, 'Icon-App-40x40@3x.png': 120,
  'Icon-App-60x60@2x.png': 120, 'Icon-App-60x60@3x.png': 180,
  'Icon-App-76x76@1x.png': 76, 'Icon-App-76x76@2x.png': 152,
  'Icon-App-83.5x83.5@2x.png': 167, 'Icon-App-1024x1024@1x.png': 1024,
};

const MAC_DIR = 'macos/Runner/Assets.xcassets/AppIcon.appiconset';
const MAC = [16, 32, 64, 128, 256, 512, 1024];

const ANDROID_RES = 'android/app/src/main/res';
// Legacy launcher icons are in dp-scaled buckets; adaptive foregrounds are the
// same buckets at 108dp instead of 48dp.
const ANDROID = {
  'mipmap-mdpi': { legacy: 48, fg: 108 },
  'mipmap-hdpi': { legacy: 72, fg: 162 },
  'mipmap-xhdpi': { legacy: 96, fg: 216 },
  'mipmap-xxhdpi': { legacy: 144, fg: 324 },
  'mipmap-xxxhdpi': { legacy: 192, fg: 432 },
};

// --- Chrome colours that live outside Dart --------------------------------

function writeAndroidBackground() {
  const dest = p(ANDROID_RES, 'values/ic_launcher_background.xml');
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.writeFileSync(
    dest,
    '<?xml version="1.0" encoding="utf-8"?>\n' +
      '<!-- Generated by tool/branding/generate_icons.mjs from brand.json. -->\n' +
      '<resources>\n' +
      `    <color name="ic_launcher_background">${BG}</color>\n` +
      '</resources>\n',
  );
  console.log('synced android ic_launcher_background.xml');
}

function syncWebManifest() {
  const dest = p('web/manifest.json');
  const manifest = JSON.parse(fs.readFileSync(dest, 'utf8'));
  manifest.background_color = BG;
  manifest.theme_color = BG;
  fs.writeFileSync(dest, `${JSON.stringify(manifest, null, 4)}\n`);
  console.log('synced web/manifest.json colours');
}

// --- Main -----------------------------------------------------------------

async function main() {
  const master = await buildMaster();
  const jobs = [];

  for (const [file, size] of Object.entries(IOS)) {
    jobs.push(render(master, size, 'fullbleed', p(IOS_DIR, file), { opaque: true }));
  }
  for (const size of MAC) {
    jobs.push(render(master, size, 'macos', p(MAC_DIR, `app_icon_${size}.png`)));
  }
  for (const [bucket, { legacy, fg }] of Object.entries(ANDROID)) {
    jobs.push(render(master, legacy, 'fullbleed', p(ANDROID_RES, bucket, 'ic_launcher.png')));
    jobs.push(render(master, fg, 'adaptiveFg', p(ANDROID_RES, bucket, 'ic_launcher_foreground.png')));
    jobs.push(render(master, fg, 'monochrome', p(ANDROID_RES, bucket, 'ic_launcher_monochrome.png')));
  }
  jobs.push(render(master, 192, 'fullbleed', p('web/icons/Icon-192.png')));
  jobs.push(render(master, 512, 'fullbleed', p('web/icons/Icon-512.png')));
  jobs.push(render(master, 192, 'maskable', p('web/icons/Icon-maskable-192.png')));
  jobs.push(render(master, 512, 'maskable', p('web/icons/Icon-maskable-512.png')));
  jobs.push(render(master, 32, 'fullbleed', p('web/favicon.png'), { opaque: true }));
  // Human-readable reference copy of the current icon.
  jobs.push(render(master, 1024, 'fullbleed', path.join(HERE, 'app_icon_preview.png'), { opaque: true }));

  await Promise.all(jobs);
  console.log(`rendered ${jobs.length} icon files`);

  writeAndroidBackground();
  syncWebManifest();
  console.log('\nDone. Remember to run `flutter test` — brand_test.dart checks');
  console.log('lib/core/theme.dart still matches brand.json.');
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
