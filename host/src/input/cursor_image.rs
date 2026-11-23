use std::{mem::size_of, ptr, slice};

use extscreen_common::protocol::{CURSOR_IMAGE_HEADER_SIZE, MAX_CURSOR_IMAGE_SIDE};
use windows::Win32::Foundation::HANDLE;
use windows::Win32::Graphics::Gdi::{
    CreateCompatibleDC, CreateDIBSection, DeleteDC, DeleteObject, GdiFlush, GetObjectW,
    SelectObject, BITMAP, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS, HBRUSH, HDC,
    HGDIOBJ,
};
use windows::Win32::UI::WindowsAndMessaging::{
    DrawIconEx, GetIconInfo, HCURSOR, HICON, ICONINFO, DI_NORMAL,
};

/// Renders the current Windows cursor shape at its own size, including custom themed cursors.
/// For animated cursors DrawIconEx's step zero supplies the representative frame.
pub(super) fn cursor_image(cursor: HCURSOR) -> Option<Vec<u8>> {
    let icon = HICON(cursor.0);
    unsafe {
        let mut info = ICONINFO::default();
        GetIconInfo(icon, &mut info).ok()?;
        let monochrome = info.hbmColor.is_invalid();
        let source = if monochrome { info.hbmMask } else { info.hbmColor };
        let mut bitmap = BITMAP::default();
        let read = GetObjectW(
            HGDIOBJ(source.0),
            size_of::<BITMAP>() as i32,
            Some((&mut bitmap as *mut BITMAP).cast()),
        );
        // GetIconInfo gives the caller ownership of the two bitmap copies.
        if !info.hbmMask.is_invalid() {
            let _ = DeleteObject(HGDIOBJ(info.hbmMask.0));
        }
        if !info.hbmColor.is_invalid() {
            let _ = DeleteObject(HGDIOBJ(info.hbmColor.0));
        }
        if read == 0 {
            return None;
        }
        let width = bitmap.bmWidth;
        // A monochrome cursor stores its AND and XOR masks one above the other.
        let height = if monochrome { bitmap.bmHeight / 2 } else { bitmap.bmHeight };
        let max = i32::from(MAX_CURSOR_IMAGE_SIDE);
        if !(1..=max).contains(&width) || !(1..=max).contains(&height)
            || info.xHotspot >= width as u32 || info.yHotspot >= height as u32
        {
            return None;
        }
        dib_cursor(icon, width, height, info.xHotspot as u16, info.yHotspot as u16)
    }
}

unsafe fn dib_cursor(icon: HICON, width: i32, height: i32, hot_x: u16, hot_y: u16) -> Option<Vec<u8>> {
    let dc = CreateCompatibleDC(HDC::default());
    if dc.is_invalid() {
        return None;
    }
    let format = BITMAPINFO {
        bmiHeader: BITMAPINFOHEADER {
            biSize: size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: width,
            biHeight: -height,
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            ..Default::default()
        },
        ..Default::default()
    };
    let mut bits = ptr::null_mut();
    let result = CreateDIBSection(dc, &format, DIB_RGB_COLORS, &mut bits, HANDLE::default(), 0)
        .ok()
        .and_then(|dib| {
            let previous = SelectObject(dc, HGDIOBJ(dib.0));
            let image = (!previous.is_invalid() && !bits.is_null()).then(|| {
                let pixels = slice::from_raw_parts_mut(bits.cast::<u8>(), width as usize * height as usize * 4);
                render_on_backgrounds(dc, icon, width, height, pixels, hot_x, hot_y)
            }).flatten();
            if !previous.is_invalid() {
                SelectObject(dc, previous);
            }
            let _ = DeleteObject(HGDIOBJ(dib.0));
            image
        });
    let _ = DeleteDC(dc);
    result
}

unsafe fn render_on_backgrounds(
    dc: HDC, icon: HICON, width: i32, height: i32, pixels: &mut [u8], hot_x: u16, hot_y: u16,
) -> Option<Vec<u8>> {
    // Rendering on black and white recovers alpha for both premultiplied and legacy mask cursors.
    pixels.fill(0);
    DrawIconEx(dc, 0, 0, icon, width, height, 0, HBRUSH::default(), DI_NORMAL).ok()?;
    let _ = GdiFlush();
    let mut image = Vec::with_capacity(CURSOR_IMAGE_HEADER_SIZE + pixels.len());
    for word in [width as u16, height as u16, hot_x, hot_y] {
        image.extend_from_slice(&word.to_le_bytes());
    }
    image.extend_from_slice(pixels);

    pixels.fill(255);
    DrawIconEx(dc, 0, 0, icon, width, height, 0, HBRUSH::default(), DI_NORMAL).ok()?;
    let _ = GdiFlush();
    let mut has_ink = false;
    for (black, white) in image[CURSOR_IMAGE_HEADER_SIZE..].chunks_exact_mut(4).zip(pixels.chunks_exact(4)) {
        let alpha = 255 - white[1].saturating_sub(black[1]);
        black[3] = alpha;
        if alpha != 0 {
            has_ink = true;
            for color in &mut black[..3] {
                *color = ((u16::from(*color) * 255 + u16::from(alpha) / 2) / u16::from(alpha))
                    .min(255) as u8;
            }
        }
    }
    has_ink.then_some(image)
}
