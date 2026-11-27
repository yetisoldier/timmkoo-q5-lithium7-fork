#!/system/bin/sh
# Run on the rooted Q5 after pushing build_branding.py outputs into $1.
# Backs up each changed device file before atomically replacing it.
set -eu
stage=${1:-/data/local/tmp/codex-branding}
backup=/data/local/tmp/codex-branding-rollback
[ "$(id -u)" = 0 ]
[ "$(wc -c < "$stage/logo-gnome.partition")" -eq 3145728 ]
grep -q 'logo.*0x0000000000300000' /proc/dumchar_info
[ ! -e "$backup" ] || { echo "Rollback directory already exists; refusing to overwrite"; exit 1; }
mkdir -m 700 "$backup"
cp /system/framework/framework-res.apk "$backup/framework-res.apk"
cp /system/media/bootanimation.zip "$backup/bootanimation.zip"
cp /data/system/users/0/wallpaper "$backup/wallpaper"
cp /data/system/users/0/wallpaper_orig "$backup/wallpaper_orig"
cp /data/system/users/0/wallpaper_info.xml "$backup/wallpaper_info.xml"
dd if=/dev/logo of="$backup/logo.partition" bs=4096 count=768

mount -o remount,rw /system
trap 'sync; mount -o remount,ro /dev/block/mmcblk0p5 /system || echo "Read-only remount deferred until required reboot"' EXIT
cp "$stage/framework-res.apk" /system/framework/framework-res.apk.codex-new
chmod 0644 /system/framework/framework-res.apk.codex-new
chown 0:2000 /system/framework/framework-res.apk.codex-new
chcon u:object_r:system_file:s0 /system/framework/framework-res.apk.codex-new
mv /system/framework/framework-res.apk.codex-new /system/framework/framework-res.apk
cp "$stage/bootanimation.zip" /system/media/bootanimation.zip.codex-new
chmod 0644 /system/media/bootanimation.zip.codex-new
chown 0:2000 /system/media/bootanimation.zip.codex-new
chcon u:object_r:system_file:s0 /system/media/bootanimation.zip.codex-new
mv /system/media/bootanimation.zip.codex-new /system/media/bootanimation.zip

for filename in wallpaper wallpaper_orig; do
    cp "$stage/gnome-480x800.png" "/data/system/users/0/$filename"
    chmod 0600 "/data/system/users/0/$filename"
    chown 1000:1000 "/data/system/users/0/$filename"
    chcon u:object_r:wallpaper_file:s0 "/data/system/users/0/$filename"
done
cp "$stage/wallpaper_info.xml" /data/system/users/0/wallpaper_info.xml
chmod 0600 /data/system/users/0/wallpaper_info.xml
chown 1000:1000 /data/system/users/0/wallpaper_info.xml
chcon u:object_r:system_data_file:s0 /data/system/users/0/wallpaper_info.xml

dd if="$stage/logo-gnome.partition" of=/dev/logo bs=4096 count=768
sync
dd if=/dev/logo of="$stage/logo-readback.partition" bs=4096 count=768
cmp "$stage/logo-gnome.partition" "$stage/logo-readback.partition"
sha256sum /system/framework/framework-res.apk /system/media/bootanimation.zip \
    /data/system/users/0/wallpaper "$stage/logo-readback.partition"
echo "Branding installed and LOGO partition readback verified. Reboot required."
