# MT6582 hardware H.264 playback — D42-R3

The original Lithium image always preferred software decoders for ordinary
media. Restoring decoder registration alone was insufficient: dependencies,
legacy APIs, process permissions, the syscall policy and DMA buffer lifetime
also needed correction. The kernel remains D42; R3 changes its ramdisk only.

## Implemented changes

* Remove the unconditional software-preference OR in Lithium's
  MediaCodecList::findMatchingCodecs (file offset 0xc14de, original bytes
  45f00105). Caller-supplied flags and the existing `_cam` MIME path remain.
* Restore the two missing small T-ROM libraries libmhalImageCodec and
  libmmprofile. Their source image matches the existing donor manifest:
  3d5350e7fc0bb6d6b3e78a572e19217e2cc26a876844dbbc7ee513c25f1cd839.
* Supply a private compatibility library for the missing AwesomePlayer timing
  member. This returns the vendor's -1/unavailable-clock sentinel and never
  dereferences an obsolete AwesomePlayer object. NuPlayer controls presentation
  timestamps. Returning wall-clock time here would be incorrect.
* Register the existing MTK AVC decoder, with its actual maximum output size
  1280x736 and an input-allocation quirk. The initial Nougat UseBuffer path
  failed MVA registration; AllocateBuffer plus the corrected memory limit works.
* Add media GID to the codec service so it can open the 0660 Vcodec device.
  Keep the service UID 1046 and its sandbox. Add only the missing calls observed
  in native failure traces: sched_getparam, mlock, munlock and fsync.
* Raise only this codec process's MEMLOCK limit from 64 KiB to 32 MiB. Android 7
  init has no per-service rlimit option; R3 runs a guarded startup helper after
  each codec-service start. It verifies both the executable and UID, accepts no
  caller-supplied PID, and leaves other processes' limits unchanged. The new
  limit was verified after reboot and service restart.

The original libm4u calls mlock during MVA allocation but omits munlock on
successful deallocation. Repeated playback retained roughly 10–18 MiB of locks
in our tests. The private compatibility library now wraps only the two M4U
imports in libvcodec_utility. It releases a range only after successful device
deallocation, tracks overlapping pages, serializes allocation/free operations,
preserves errno and fails closed if tracking is exhausted. The system-wide
libm4u and other graphics clients remain byte-identical; the defaults builder
asserts that shared library's input hash.

No audio HAL, audio policy, amplifier calibration or touch kernel changes are
part of this media adaptation.

## Verification on the connected Q5

* Full 16 MiB R3 boot readback matched
  e54b023a3fd941c74d1ecf479412994cf74c595e719eb5f9f1eb9ae5cf617a44.
* A 30-second 1280x720/24fps baseline H.264 clip rendered correctly. Captured
  counters reached 708 frames with zero drops; hardware Vcodec IRQ count rose
  from zero to 719. The decoder memory limit survived reboot.
* After the cleanup fix, four consecutive clips ran in the same codec PID,
  without crashes. Completed runs returned VmLck to zero; RSS stayed near
  20 MiB rather than accumulating locked buffers. The first measurement was
  slightly before playback completion and is not an idle-memory result.
* Pause/play and dragging the seek bar exercised the live decoder; playback
  continued without decoder errors. Locks returned to zero after closing it.
* A 720p High Profile clip also rendered with zero captured drops.
* The 1920x1080 test rendered through FFmpeg software fallback, with zero
  captured drops. The MTK backend explicitly rejects that size. Do not claim
  hardware 1080p support: this ROM's NuPlayer dump can retain the first decoder
  name even after fallback. The component log and rendered frame were checked.
* Host ASan/UBSan tests cover overlapping pages, failed device deallocation,
  failed allocation, duplicate/unknown frees, address overflow, tracking
  exhaustion and errno preservation.

These are bounded media tests, not evidence for every codec/profile, streaming
service, DRM implementation or battery-life target.

## Reproduction

`manifests/media-compat-donors.json` pins original Lithium libraries/configs and
the two T-ROM dependency files. Build outputs are never committed.

```sh
python3 build/build_media_compat.py --inputs /path/to/pinned-media-inputs \
  --compiler /path/to/arm-eabi-4.8/bin/arm-eabi-gcc --out out/media-compat
python3 build/patch_codec_boot.py out/boot-d42-r2.img out/boot-d42-r3.img
# Add --media out/media-compat to build/apply_system_defaults.py.
gcc -O1 -g -Wall -Wextra -fsanitize=address,undefined \
  -fno-omit-frame-pointer tests/test_media_memory.c -o /tmp/q5-media-test
/tmp/q5-media-test
```

R3 requires the generated system helper alongside the corrected boot image.
The packager rejects a boot without the FM, USB and codec-startup corrections.

Reference for the legacy clock behavior:
[MT6582 AwesomePlayer implementation](https://github.com/CM-Huawei/Source_MT6582/blob/master/frameworks/av/media/libstagefright/AwesomePlayer.cpp).
The 36-byte implementation in the pinned T-ROM stagefright library was also
disassembled and agrees with that first-frame/seek sentinel behavior.
