# Galaxy Book4 light sensor fix

Makes automatic screen brightness usable on the Samsung Galaxy Book4 Ultra
under Linux, by correcting the scale of its ambient light sensor.

Verified on the **Galaxy Book4 Ultra (960XGL)**. Other Galaxy Book4 models may
have the same sensor behaviour, but none have been tested — see
[Other models](#other-models).

## The problem

On Linux the light sensor of this laptop reports values roughly ten times lower
than the actual illuminance:

| Condition                              | Reported |
|----------------------------------------|---------:|
| Sensor covered                         |  0.8 lux |
| Room lit by a lamp in the evening      |  5.7 lux |
| Phone flashlight a few centimetres away |  830 lux |

A phone flashlight at that distance is well above 10 000 lux, and a lit room is
normally 50–300 lux.

KDE Plasma's automatic brightness keeps a curve of eleven points (the lux level
for 0 %, 10 %, … 100 % brightness) and requires at least 1 lux between
neighbouring points. With all indoor lighting squeezed into a handful of lux,
that curve has no room: brightness ends up moving only within a narrow band, and
correcting it by hand does not teach it anything lasting.

## The fix

The sensor is exposed by the Intel sensor hub (HID `8087:0AC2`), whose report
descriptor declares the illuminance field with unit exponent −3. A small
[HID-BPF](https://docs.kernel.org/hid/hid-bpf.html) program changes that
exponent to −2 before the kernel parses the descriptor, so every reading comes
out ten times larger. Nothing else is modified: no kernel patch, no change to
Plasma or iio-sensor-proxy.

The program is loaded by
[udev-hid-bpf](https://libevdev.pages.freedesktop.org/udev-hid-bpf/) from a udev
rule, so it applies on every boot.

## Requirements

* Linux 6.11 or newer, built with `CONFIG_HID_BPF` (Fedora and Debian kernels are)
* The `udev-hid-bpf` package — the installer fetches it with `dnf` or `apt-get`.
  It is only packaged in recent releases; on older ones the installer stops
  with an error.
* `iio-sensor-proxy`, which Plasma uses to read the sensor (also installed if
  missing)

## Install

```sh
git clone https://github.com/Cir0cuit/galaxybook4-light-sensor-fix.git
cd galaxybook4-light-sensor-fix
./install.sh
```

The script asks for root through `sudo`. It checks that the machine and the
sensor descriptor are the ones the fix was written for, installs the program,
loads it immediately and confirms that the scale changed. No reboot is needed.

```sh
./install.sh --status      # is the fix active?
./install.sh --uninstall   # remove it
```

### After installing

Plasma's previously learned curve no longer matches the new readings, so the
screen will most likely jump to full brightness. Make sure automatic brightness
is enabled under *System Settings → Display & Monitor*, then set the brightness
you want in two or three different conditions — a dark room, lamp light,
daylight. Each correction now sticks, and the curve settles after a few.

## Other models

The same sensor hub ID is used by many laptops whose readings are correct, and
applying the fix there would make the screen far too bright. For that reason
the installer refuses to run on anything but the 960XGL unless `--force` is
given.

To find out whether your machine is affected, watch the sensor:

```sh
monitor-sensor --light
```

and compare with the table above. If a lit room reads only a few lux and a phone
flashlight held against the sensor stays under a couple of thousand, your sensor
under-reports in the same way and `./install.sh --force` is worth trying. The
installer still verifies the descriptor byte for byte and stops if it differs.

Do not poll `/sys/bus/iio/devices/iio:device*/in_illuminance_raw` in a loop to
watch the sensor. On this hardware that stalls the readings other programs
receive until the polling stops.

If you try this on another model, a report of the result — working or not — is
welcome in the issues, together with the output of
`cat /sys/class/dmi/id/product_name`.

## Limitations

* **The factor of ten is an estimate.** It is the smallest correction consistent
  with the measurements above, not a calibration against a lux meter.
* **Firmware updates.** The program only applies to a descriptor of exactly
  1230 bytes with the expected contents. If a firmware update changes the
  descriptor the fix quietly stops applying; `./install.sh --status` shows that.
* **Colour temperature.** The kernel driver uses one scale for every channel of
  the sensor, so the colour temperature channel becomes ten times too large.
  Nothing in a standard Plasma setup reads it.
* Tested with Plasma 6.7 on Fedora 44 only. The installer's Debian/Ubuntu path
  is written but has not been run.

## Building

The compiled program is embedded in `install.sh`, so installing needs no
compiler. To rebuild it from `src/`:

```sh
sudo dnf install clang bpftool libbpf-devel     # Fedora
sudo apt install clang bpftool libbpf-dev       # Debian/Ubuntu
make          # builds the .bpf.o
make embed    # writes it, and its checksum, into install.sh
```

To use a different factor, change `EXP_MINUS_2` in the source: `0x0f` is
exponent −1, a factor of one hundred.

## How this was built

The diagnosis and the code were produced with an AI coding agent — Claude Code —
under human direction, and verified on the one machine described above.

## License

GPL-2.0-only. `src/hid_bpf.h` and `src/hid_bpf_helpers.h` come from udev-hid-bpf
and are © Benjamin Tissoires.
