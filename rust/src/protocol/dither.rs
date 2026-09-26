// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

//! Turn a composed label into the two colours a thermal head can print.
//!
//! The composer paints in full colour; a raster printer burns a dot or does
//! not. This reduces an RGBA canvas to RGB888 whose every channel is 0 or
//! 255, so every printer handler's own 50% threshold (see
//! `image_upload::brightness_mask`) passes it through bit-exact — the
//! handlers stay untouched, and what the preview shows is what prints.
//!
//! Alpha composites over white (the paper), so an unpainted canvas prints
//! nothing. Luma uses the same BT.601 weights as `brightness_mask`.

/// How grey becomes black and white.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DitherMode {
    /// Black below `threshold`, white at or above it. Right for text, QR
    /// codes and line art: edges stay crisp and nothing is speckled.
    Threshold,
    /// Floyd–Steinberg error diffusion (7/16, 3/16, 5/16, 1/16). Right for
    /// photos: tones become dot density.
    FloydSteinberg,
    /// Atkinson error diffusion: spreads 6/8 of the error, which keeps
    /// highlights and shadows cleaner than Floyd–Steinberg on a head that
    /// bleeds.
    Atkinson,
}

/// Reduce `rgba` (straight alpha, row-major, `width * height * 4` bytes) to
/// black-and-white RGB888. `threshold` is the luma (0-255) at and above which
/// a pixel is white; the diffusion modes quantise against it too, so it acts
/// as a brightness control for photos.
pub fn to_mono_rgb(
    rgba: &[u8],
    width: usize,
    height: usize,
    mode: DitherMode,
    threshold: u8,
) -> Vec<u8> {
    let n = width * height;
    let mut luma: Vec<f32> = rgba
        .chunks_exact(4)
        .take(n)
        .map(|px| {
            let a = f32::from(px[3]) / 255.0;
            let y =
                (299.0 * f32::from(px[0]) + 587.0 * f32::from(px[1]) + 114.0 * f32::from(px[2]))
                    / 1000.0;
            // Over white paper.
            y * a + 255.0 * (1.0 - a)
        })
        .collect();
    luma.resize(n, 255.0);

    let t = f32::from(threshold);
    let mut out = vec![0u8; n * 3];
    for y in 0..height {
        for x in 0..width {
            let i = y * width + x;
            let old = luma[i];
            let white = old >= t;
            let new = if white { 255.0 } else { 0.0 };
            if white {
                out[i * 3..i * 3 + 3].copy_from_slice(&[255, 255, 255]);
            }
            let err = old - new;
            match mode {
                DitherMode::Threshold => {}
                DitherMode::FloydSteinberg => {
                    spread(&mut luma, width, height, x, y, 1, 0, err * 7.0 / 16.0);
                    spread(&mut luma, width, height, x, y, -1, 1, err * 3.0 / 16.0);
                    spread(&mut luma, width, height, x, y, 0, 1, err * 5.0 / 16.0);
                    spread(&mut luma, width, height, x, y, 1, 1, err / 16.0);
                }
                DitherMode::Atkinson => {
                    let e = err / 8.0;
                    for (dx, dy) in [(1, 0), (2, 0), (-1, 1), (0, 1), (1, 1), (0, 2)] {
                        spread(&mut luma, width, height, x, y, dx, dy, e);
                    }
                }
            }
        }
    }
    out
}

#[allow(clippy::too_many_arguments)]
fn spread(
    luma: &mut [f32],
    width: usize,
    height: usize,
    x: usize,
    y: usize,
    dx: isize,
    dy: usize,
    amount: f32,
) {
    let nx = x as isize + dx;
    let ny = y + dy;
    if nx < 0 || nx as usize >= width || ny >= height {
        return;
    }
    luma[ny * width + nx as usize] += amount;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn grey(level: u8, w: usize, h: usize) -> Vec<u8> {
        [level, level, level, 255].repeat(w * h)
    }

    fn blacks(rgb: &[u8]) -> usize {
        rgb.chunks_exact(3).filter(|p| p[0] == 0).count()
    }

    #[test]
    fn every_mode_emits_only_black_and_white() {
        let mut rgba = Vec::new();
        for i in 0..64u32 {
            let v = (i * 4) as u8;
            rgba.extend_from_slice(&[v, 255 - v, v / 2, 255]);
        }
        for mode in [
            DitherMode::Threshold,
            DitherMode::FloydSteinberg,
            DitherMode::Atkinson,
        ] {
            let out = to_mono_rgb(&rgba, 8, 8, mode, 128);
            assert_eq!(out.len(), 8 * 8 * 3);
            assert!(out.iter().all(|&b| b == 0 || b == 255), "{mode:?}");
            // Each pixel's three channels agree.
            assert!(out.chunks_exact(3).all(|p| p[0] == p[1] && p[1] == p[2]));
        }
    }

    #[test]
    fn threshold_splits_at_the_level() {
        assert_eq!(
            blacks(&to_mono_rgb(
                &grey(127, 4, 4),
                4,
                4,
                DitherMode::Threshold,
                128
            )),
            16
        );
        assert_eq!(
            blacks(&to_mono_rgb(
                &grey(128, 4, 4),
                4,
                4,
                DitherMode::Threshold,
                128
            )),
            0
        );
    }

    #[test]
    fn transparent_pixels_are_paper() {
        let rgba = [0u8, 0, 0, 0].repeat(16);
        for mode in [DitherMode::Threshold, DitherMode::FloydSteinberg] {
            assert_eq!(blacks(&to_mono_rgb(&rgba, 4, 4, mode, 128)), 0);
        }
    }

    #[test]
    fn diffusion_renders_mid_grey_as_about_half_dots() {
        for mode in [DitherMode::FloydSteinberg, DitherMode::Atkinson] {
            let out = to_mono_rgb(&grey(128, 32, 32), 32, 32, mode, 128);
            let ratio = blacks(&out) as f32 / 1024.0;
            // Atkinson drops 1/4 of the error, so it lightens a little.
            assert!((0.3..=0.6).contains(&ratio), "{mode:?}: {ratio}");
        }
        // Where threshold would print a solid block or nothing at all.
        assert_eq!(
            blacks(&to_mono_rgb(
                &grey(128, 32, 32),
                32,
                32,
                DitherMode::Threshold,
                128
            )),
            0
        );
    }

    #[test]
    fn the_output_survives_the_handlers_own_threshold_unchanged() {
        let out = to_mono_rgb(&grey(90, 16, 16), 16, 16, DitherMode::FloydSteinberg, 128);
        let mask = crate::protocol::image_upload::brightness_mask(&out);
        for (px, bright) in out.chunks_exact(3).zip(mask) {
            assert_eq!(px[0] == 255, bright);
        }
    }

    #[test]
    fn a_short_buffer_pads_with_paper_instead_of_panicking() {
        let out = to_mono_rgb(&[0, 0, 0, 255], 2, 2, DitherMode::Atkinson, 128);
        assert_eq!(out.len(), 12);
        assert_eq!(&out[..3], &[0, 0, 0]);
    }
}
