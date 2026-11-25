//! Opt-in compatibility hooks for known title builds.
//!
//! Only per-build offsets and short byte signatures live here (asset policy:
//! nothing of the title itself). Every hook checks the build's hash and the
//! exact bytes it replaces, and does nothing otherwise.

use windows_sys::Win32::System::Diagnostics::Debug::FlushInstructionCache;
use windows_sys::Win32::System::Memory::{PAGE_EXECUTE_READWRITE, VirtualProtect};
use windows_sys::Win32::System::Threading::GetCurrentProcess;

/// First 16 hex digits of the BLAKE3 of the Series X 1.0.2.1 executable.
const BUILD_1_0_2_1: &str = "b99f876b74d4a77f";

/// Environment variable that turns the watchdog hook on.
pub(crate) const NO_WATCHDOG_ENV: &str = "VICTORY_NO_WATCHDOG";

/// One code patch: `rva` must hold exactly `expect` before `new` is written.
struct Patch {
    what: &'static str,
    rva: usize,
    expect: &'static [u8],
    new: &'static [u8],
}

/// The title's watchdog thread ends the process on purpose when its main
/// thread has not advanced for about 30 one-second ticks. Two places do it:
/// the handler it calls (`mov dword ptr [0], imm32`) and, when the handler
/// returns or is unset, a fallback right after the call (`mov dword ptr [0],
/// 0; int3`). Jumping over the whole block returns the loop to its normal
/// path; the first patch makes the handler harmless if something else calls it.
const WATCHDOG: &[Patch] = &[
    Patch {
        what: "watchdog: skip the call and the fallback fault",
        rva: 0x2215c27,
        // mov rax, [rip + disp32] (the handler pointer)
        expect: &[0x48, 0x8B, 0x05, 0x1A, 0x07, 0xFA, 0x04],
        // jmp +0x18 (to the loop's normal continuation), then NOPs
        new: &[0xEB, 0x18, 0x90, 0x90, 0x90, 0x90, 0x90],
    },
    Patch {
        what: "watchdog: handler's deliberate fault",
        rva: 0x23cf683,
        expect: &[0xC7, 0x04, 0x25, 0, 0, 0, 0, 0x21, 0xD4, 0x8B, 0x4D],
        // an eleven-byte NOP
        new: &[0x66, 0x66, 0x2E, 0x0F, 0x1F, 0x84, 0, 0, 0, 0, 0],
    },
];

/// The title's object pools on build 1.0.2.1 (upstream issue #698): after
/// about 10 minutes one runs out and the title stops at an `int3`. These
/// are where its state lives, read when that happens (none of the title's
/// own bytes: offsets only).
mod pool_698 {
    /// The `int3` taken when the pool's free list is empty.
    pub(super) const EMPTY_INT3: usize = 0x5149aec;
    /// The `int3` taken when the ring of objects to destroy is full.
    pub(super) const RING_FULL_INT3: usize = 0x49db15;
    /// Pointers to the two pools; each holds its capacity at +0xc and the
    /// objects alive at +0x10.
    pub(super) const POOLS: [usize; 2] = [0xabbe2e8, 0xa9ec938];
    /// The ring of objects waiting to be destroyed: capacity, write and
    /// read positions (u32 each).
    pub(super) const RING_CAPACITY: usize = 0x926a988;
    pub(super) const RING_WRITE: usize = 0x926a998;
    pub(super) const RING_READ: usize = 0x926a99c;
    /// The first and last rank of that ring the title cannot destroy yet
    /// (two u32).
    pub(super) const BLOCKED: usize = 0xa4a0440;
    /// Pointer to the world; at +0x39a8 the flags (bit 4: destroying on),
    /// at +0x3950 and +0x3952 its event counts (u16).
    pub(super) const WORLD: usize = 0x99aad30;
}

/// The base of a build 1.0.2.1 image, for [`pool_state`]; 0 otherwise.
static POOL_IMAGE: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// Notes the mapped title image at `base` whose original BLAKE3 is `hash`.
pub(crate) fn note_image(base: usize, hash: &blake3::Hash) {
    if hash.to_hex().starts_with(BUILD_1_0_2_1) {
        POOL_IMAGE.store(base, std::sync::atomic::Ordering::Relaxed);
    }
}

/// For an exception at `at`: the state of the title's object pools when it
/// is one of the `int3`s of upstream issue #698, else `None`.
pub(crate) fn pool_state(at: usize) -> Option<String> {
    use pool_698::*;
    let base = POOL_IMAGE.load(std::sync::atomic::Ordering::Relaxed);
    if base == 0 || (at != base + EMPTY_INT3 && at != base + RING_FULL_INT3) {
        return None;
    }
    let u32_at = |a: usize| read::<4>(a).map(u32::from_le_bytes);
    let u64_at = |a: usize| read::<8>(a).map(u64::from_le_bytes);
    let mut text = String::from("  title object pools (issue #698):");
    for (i, rva) in POOLS.iter().enumerate() {
        let pool = u64_at(base + rva).filter(|&p| p != 0).map(|p| p as usize);
        let line = match pool.map(|p| (u32_at(p + 0xc), u32_at(p + 0x10))) {
            Some((Some(capacity), Some(alive))) => format!("{alive} alive of {capacity}"),
            Some(_) => "unreadable".to_owned(),
            None => "none".to_owned(),
        };
        text.push_str(&format!("\n    pool {}: {line}", i + 1));
    }
    if let (Some(capacity), Some(write), Some(read)) = (
        u32_at(base + RING_CAPACITY),
        u32_at(base + RING_WRITE),
        u32_at(base + RING_READ),
    ) {
        let waiting = write.wrapping_sub(read) % capacity.max(1);
        text.push_str(&format!(
            "\n    ring: {waiting} of {capacity} waiting (read {read}, write {write})"
        ));
    }
    if let Some(blocked) = u64_at(base + BLOCKED) {
        let (first, last) = (blocked as u32, (blocked >> 32) as u32);
        text.push_str(&format!("\n    blocked from rank {first} to {last}"));
    }
    let world = u64_at(base + WORLD).filter(|&w| w != 0).map(|w| w as usize);
    if let Some(w) = world {
        let flags = u32_at(w + 0x39a8);
        let events = (read::<2>(w + 0x3950), read::<2>(w + 0x3952));
        if let (Some(flags), (Some(a), Some(b))) = (flags, events) {
            let on = if flags & 0x10 != 0 { "on" } else { "off" };
            text.push_str(&format!(
                "\n    world: destroying {on}, events {} and {}",
                u16::from_le_bytes(a),
                u16::from_le_bytes(b)
            ));
        }
    }
    Some(text)
}

/// `N` bytes at `address` of this process, `None` where they cannot be
/// read: a crash report must not fault on a stale pointer.
fn read<const N: usize>(address: usize) -> Option<[u8; N]> {
    use windows_sys::Win32::System::Diagnostics::Debug::ReadProcessMemory;
    let mut bytes = [0u8; N];
    let mut got = 0;
    // SAFETY: the kernel copies, and reports an unreadable source instead
    // of faulting; the destination is ours.
    let ok = unsafe {
        ReadProcessMemory(
            GetCurrentProcess(),
            address as *const _,
            bytes.as_mut_ptr().cast(),
            N,
            &mut got,
        )
    };
    (ok != 0 && got == N).then_some(bytes)
}

/// Applies the watchdog patches whose bytes match. Returns how many applied.
///
/// # Safety
/// `base` is the mapped image whose original BLAKE3 is `hash`, and no title
/// code is running yet.
pub(crate) unsafe fn disarm_watchdog(base: usize, hash: &blake3::Hash) -> usize {
    if !hash.to_hex().starts_with(BUILD_1_0_2_1) {
        return 0;
    }
    WATCHDOG
        .iter()
        // SAFETY: forwarded from this function's contract.
        .filter(|p| unsafe { apply(base, p) })
        .count()
}

/// # Safety
/// See `disarm_watchdog`.
unsafe fn apply(base: usize, p: &Patch) -> bool {
    let at = (base + p.rva) as *mut u8;
    // SAFETY: the offset is inside the mapped .text of this exact build.
    let now = unsafe { std::slice::from_raw_parts(at, p.expect.len()) };
    if now != p.expect || p.new.len() != p.expect.len() {
        tracing::warn!(
            what = p.what,
            "hook skipped: the bytes are not the expected ones"
        );
        return false;
    }
    let mut old = 0;
    // SAFETY: changing the protection of those bytes only, restored below.
    if unsafe { VirtualProtect(at as _, p.new.len(), PAGE_EXECUTE_READWRITE, &mut old) } == 0 {
        return false;
    }
    // SAFETY: writable now; the bytes are the ones checked above.
    unsafe {
        std::ptr::copy_nonoverlapping(p.new.as_ptr(), at, p.new.len());
        VirtualProtect(at as _, p.new.len(), old, &mut old);
        FlushInstructionCache(GetCurrentProcess(), at as _, p.new.len());
    }
    tracing::info!(what = p.what, "hook applied");
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use windows_sys::Win32::System::Memory::{
        MEM_COMMIT, MEM_RELEASE, MEM_RESERVE, PAGE_READWRITE, VirtualAlloc, VirtualFree,
    };

    /// A stand-in image reaching past the last patch, with each patch's
    /// expected bytes at its offset.
    struct Image(usize);

    impl Image {
        fn new() -> Image {
            let len = WATCHDOG
                .iter()
                .map(|p| p.rva + p.expect.len())
                .max()
                .unwrap();
            // SAFETY: a fresh allocation; untouched pages cost nothing.
            let base = unsafe {
                VirtualAlloc(
                    std::ptr::null(),
                    len,
                    MEM_RESERVE | MEM_COMMIT,
                    PAGE_READWRITE,
                )
            };
            assert!(!base.is_null());
            for p in WATCHDOG {
                // SAFETY: inside the allocation.
                unsafe {
                    std::ptr::copy_nonoverlapping(
                        p.expect.as_ptr(),
                        base.cast::<u8>().add(p.rva),
                        p.expect.len(),
                    )
                };
            }
            Image(base as usize)
        }

        fn at(&self, p: &Patch) -> &[u8] {
            // SAFETY: inside the allocation.
            unsafe { std::slice::from_raw_parts((self.0 + p.rva) as *const u8, p.expect.len()) }
        }
    }

    impl Drop for Image {
        fn drop(&mut self) {
            // SAFETY: our allocation, no longer read.
            unsafe { VirtualFree(self.0 as *mut _, 0, MEM_RELEASE) };
        }
    }

    /// A hash whose hex starts with `hex`.
    fn hash(hex: &str) -> blake3::Hash {
        let mut bytes = [0u8; 32];
        for (i, b) in bytes.iter_mut().take(hex.len() / 2).enumerate() {
            *b = u8::from_str_radix(&hex[2 * i..2 * i + 2], 16).unwrap();
        }
        blake3::Hash::from(bytes)
    }

    /// On build 1.0.2.1 both patches go in, each over exactly its bytes.
    #[test]
    fn the_watchdog_patches_go_in_on_build_1_0_2_1() {
        let image = Image::new();
        // SAFETY: a stand-in image no code runs in.
        assert_eq!(unsafe { disarm_watchdog(image.0, &hash(BUILD_1_0_2_1)) }, 2);
        for p in WATCHDOG {
            assert_eq!(image.at(p), p.new, "{}", p.what);
        }
    }

    /// Another build is left as it is, and so is a site whose bytes are not
    /// the expected ones.
    #[test]
    fn other_builds_and_other_bytes_are_left_alone() {
        let image = Image::new();
        // SAFETY: as above.
        let applied = unsafe { disarm_watchdog(image.0, &hash("0123456789abcdef")) };
        assert_eq!(applied, 0);
        for p in WATCHDOG {
            assert_eq!(image.at(p), p.expect, "{}", p.what);
        }
        let (moved, kept) = (&WATCHDOG[0], &WATCHDOG[1]);
        // SAFETY: inside the stand-in image.
        unsafe { ((image.0 + moved.rva) as *mut u8).write(0xCC) };
        // SAFETY: as above.
        assert_eq!(unsafe { disarm_watchdog(image.0, &hash(BUILD_1_0_2_1)) }, 1);
        assert_eq!(image.at(moved)[0], 0xCC, "{}", moved.what);
        assert_eq!(image.at(kept), kept.new, "{}", kept.what);
    }

    /// At the `int3` of an empty pool, the pools', the ring's and the
    /// world's state is read from the image; anywhere else, nothing.
    #[test]
    fn the_pool_state_is_read_at_the_pools_int3() {
        use pool_698::*;
        let len = POOLS[0] + 0x1000;
        // SAFETY: a fresh allocation standing in for the image; untouched
        // pages cost nothing.
        let base = unsafe {
            VirtualAlloc(
                std::ptr::null(),
                len,
                MEM_RESERVE | MEM_COMMIT,
                PAGE_READWRITE,
            )
        } as usize;
        assert_ne!(base, 0);
        let mut pool = [0u32; 8];
        (pool[3], pool[4]) = (131_070, 131_070); // capacity, alive
        let mut world = vec![0u8; 0x39b0];
        world[0x39a8] = 0x10;
        world[0x3950..0x3952].copy_from_slice(&460u16.to_le_bytes());
        world[0x3952..0x3954].copy_from_slice(&100u16.to_le_bytes());
        let put = |rva: usize, v: u64, n: usize| {
            // SAFETY: inside the allocation.
            unsafe {
                std::ptr::copy_nonoverlapping(v.to_le_bytes().as_ptr(), (base + rva) as *mut u8, n)
            }
        };
        put(POOLS[0], pool.as_ptr() as u64, 8);
        put(RING_CAPACITY, 4096, 4);
        put(RING_WRITE, 4095, 4);
        put(RING_READ, 0, 4);
        put(BLOCKED, 7 | 4094 << 32, 8);
        put(WORLD, world.as_ptr() as u64, 8);
        note_image(base, &hash(BUILD_1_0_2_1));
        let state = pool_state(base + EMPTY_INT3).expect("the pool's int3");
        for part in [
            "pool 1: 131070 alive of 131070",
            "pool 2: none",
            "ring: 4095 of 4096 waiting (read 0, write 4095)",
            "blocked from rank 7 to 4094",
            "world: destroying on, events 460 and 100",
        ] {
            assert!(state.contains(part), "{part:?} in {state:?}");
        }
        assert!(pool_state(base + EMPTY_INT3 + 1).is_none());
        POOL_IMAGE.store(0, std::sync::atomic::Ordering::Relaxed);
        // SAFETY: our allocation, no longer read.
        unsafe { VirtualFree(base as *mut _, 0, MEM_RELEASE) };
    }
}
