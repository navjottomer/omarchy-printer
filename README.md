# Omarchy Printer

Printer status, toner levels, the print queue and scanning in the Omarchy bar.
Uses only what every Omarchy install already has — CUPS, Avahi and Python —
with no printer drivers, scanner drivers, vendor tools or extra packages.

<p align="center"><img src="preview.png" alt="Printer tab and Scan tab of the printer panel" width="760"></p>

## Features

- **Bar icon** that turns red on a problem (paper jam, out of paper, cover
  open, toner empty), shows a hollow printer when the printer is paused, a
  crossed-out printer when it is offline, and a scanner while a scan runs.
  Hover it for a one-line status.
- **Toner levels** in the printer's own colours, read straight from network
  printers so they are current, not only updated during a print job. Low toner
  turns red.
- **Status and paper:** Ready, Printing, Sleeping, Paused or Offline, any
  problem the printer reports, and the paper size that is loaded. A network
  printer that is switched off shows as Offline within about 30 seconds,
  even though CUPS itself only notices when it next tries to print.
- **Print queue** with a cancel button on each of your jobs, and *Cancel all
  my jobs*.
- **Actions:** pause or resume the printer, print a test page (press twice to
  confirm), open the printer's own web page, open printer settings.
- **Notifications** when a job finishes or fails, when paper runs out or jams,
  once when a toner runs low, and once when a job is waiting for a printer
  that is offline.
- **Scanning** on a **Scan** tab, for network multifunction printers that
  support AirScan (eSCL) — most from the last ten years:
  - source: **Auto** (the document feeder when paper is in it, else the
    glass), glass or feeder; a stack in the feeder becomes one scan
  - colour, grey or black and white; 100, 200, 300 or 600 dpi
  - A4, Letter, Legal or the largest area the scanner allows
  - PDF or JPEG, saved to `~/Pictures/Scans` (your XDG pictures folder); a
    stack from the feeder becomes one PDF
  - optionally opens the file when done; **Open** and **Folder** buttons for
    the last scan; Cancel stops the scan on the scanner too
- **Several printers:** a picker appears when more than one is set up.
- **Keyboard control** like the stock panels: arrows or h/j/k/l, Enter, x to
  cancel a job.

## Requirements

Every package below is in the official Arch repositories. Omarchy's base
install lists `cups`, `cups-filters`, `avahi`, `nss-mdns`, `uwsm` and
`system-config-printer`; the rest are normally pulled in as dependencies. The
plugin downloads nothing and needs no printer drivers or vendor tools.

| Package | Used for |
|---|---|
| `cups` | the print system: `ipptool` for status, toner and the queue; `lpstat`, `lp`, `cancel`, `cupsenable`, `cupsdisable` |
| `cups-filters` | printing the test page and driverless (IPP Everywhere / AirPrint) printing |
| `avahi` | `avahi-browse`, to find network printers and their web page |
| `nss-mdns` | resolving `.local` printer names |
| `python` | the status script (standard library only, no pip packages) |
| `dbus` | `dbus-monitor`, to hear CUPS job and printer events instead of polling |
| `libnotify` | `notify-send`, for notifications |
| `polkit` | `pkexec`, for the password prompt when pausing or resuming |
| `xdg-utils` | `xdg-open`, for the printer's web page |
| `uwsm` | launching printer settings (part of Omarchy) |
| `xdg-user-dirs` | *optional*, finds your pictures folder for scans (else `~/Pictures`) |
| `poppler` | *optional*, `pdfunite`: joins a feeder stack into one PDF on scanners that send one PDF per page |
| `system-config-printer` | *optional*, the **Settings** button |

Install anything missing with:

```sh
omarchy pkg add cups cups-filters avahi nss-mdns python dbus libnotify polkit xdg-utils system-config-printer
```

The CUPS and Avahi services must be running, and `mdns_minimal` must be in the
`hosts:` line of `/etc/nsswitch.conf` (Omarchy sets both up):

```sh
sudo systemctl enable --now cups.socket avahi-daemon.service
```

You also need a printer already added to CUPS (Omarchy's printer setup, or
`system-config-printer`). Toner and paper readings need a printer that speaks
IPP (any AirPrint, IPP Everywhere or Mopria printer); others still show status
and the queue. Network printers are recognised whether CUPS has them as
`ipps://…`, `ipp://…` or `dnssd://…`, over IPv4 or IPv6.

## Install

```sh
omarchy plugin add https://github.com/navjottomer/omarchy-printer.git --enable
```

This clones the plugin into `~/.config/omarchy/plugins/navjottomer.printer/`,
validates it and puts it on the bar.

## Update

```sh
omarchy plugin update navjottomer.printer
```

## Remove

```sh
omarchy plugin remove navjottomer.printer
```

Nothing else is left behind.

## Usage

| Action | Result |
|---|---|
| click the bar icon | open or close the panel |
| right-click the bar icon | open printer settings |
| ✕ next to a job | cancel that job |
| Pause / Resume | stop or restart the printer (asks for your password) |
| Test page | press twice within 3 seconds to print CUPS's test page (`default-testpage.pdf`) |
| Web page | open the printer's built-in web page |

Keyboard, as in the stock panels:

| Key | Action |
|---|---|
| ↑ ↓ ← → or h j k l | move between printers, jobs and buttons |
| Enter / Space | act on the highlighted item |
| x | cancel the highlighted job |
| ← → on the tab row | switch between **Printer** and **Scan** |
| ← → on a scan option | change it |
| r | refresh now |
| Tab / Shift+Tab | switch to the next bar panel |
| Esc | close |

Pausing a printer is an admin action in CUPS, so it goes through `pkexec`
and the Omarchy password prompt. Cancelling your own jobs needs no password.

## Settings

Set with `omarchy bar set navjottomer.printer <key> <value>`:

| Key | Default | Meaning |
|---|---|---|
| `tonerColors` | `real` | `real`: each toner in its own colour; `theme`: the theme accent |
| `notifications` | `true` | notify on finished jobs, paper problems, low toner and finished scans |
| `scanSource` | `auto` | `auto`, `platen` (glass) or `feeder` |
| `scanColor` | `color` | `color`, `gray` or `bw` (black and white, PDF only) |
| `scanDpi` | `300` | `100`, `200`, `300` or `600` |
| `scanSize` | `a4` | `a4`, `letter`, `legal` or `max` |
| `scanFormat` | `pdf` | `pdf` or `jpeg` |
| `scanOpen` | `false` | open the file when a scan finishes |

The scan settings are also on the **Scan** tab and are remembered.

With real colours, a very dark toner (black) is drawn in the theme's text
colour so it stays visible on a dark bar.

## How it works

`bin/omarchy-printer` is one long-lived Python process with two threads.

**Main thread — CUPS.** One `ipptool` run asks the local scheduler for
printers, jobs and the default printer. The script holds a short-lease CUPS
subscription (renewed every 5 minutes, cancelled on exit) that announces job
and printer changes over D-Bus, so updates appear at once and the scheduler
is otherwise only polled every 60 seconds as a safety net — every 2 seconds
while a job is printing, and every 15 seconds if D-Bus events are
unavailable.

**Network thread — the printers themselves.** Everything that can be slow
runs here, so it never delays the panel:

1. `avahi-browse` finds each network printer's addresses (IPv4 and IPv6) and
   web page;
2. every 15 seconds a TCP connection is opened and closed to each network
   printer (2 s limit, no new process); two misses in a row, or a printer no
   longer announced on the network, mean Offline — CUPS itself only notices
   when it next sends a job;
3. printers are asked directly for toner, loaded paper and alerts every 5
   minutes, right after a job finishes, and as soon as an offline printer
   answers again.

One JSON line goes to the panel only when something changed. The panel sends
`refresh` after an action so the result shows at once. The script exits when
the panel closes, and its `dbus-monitor` child is tied to it so it cannot be
left behind.

Idle, the whole thing measures about 0 ms of CPU per minute and 18 MB of
memory.

**Bounds.** Output from `ipptool` (1 MB) and `avahi-browse` (256 KB) is read
only up to a fixed size, and a command that prints more or runs too long is
stopped. At most 8 printers, 8 toners and 20 jobs per record, text fields
clipped to 80 characters, and each record capped at 32 KB. All
printer-supplied text is shown as plain text, never as markup. Actions run
with fixed arguments, never through a shell.

## Scanning

`bin/omarchy-printer-scan` starts when you press **Scan** and exits when the
scan is done, so scanning costs nothing the rest of the time. It speaks eSCL,
the HTTP-and-XML scan protocol behind AirScan and Mopria Scan:

1. the status script finds the scanner the same way it finds the printer —
   its `_uscans._tcp` (or `_uscan._tcp`) announcement under the printer's
   host name — and tells the panel which sources, colours and formats it has;
2. the helper checks the scanner is idle (and whether paper is in the
   feeder, for **Auto**), sends the scan settings, and saves each document
   the scanner returns until it reports there are no more pages;
3. files are created in `~/Pictures/Scans` with `O_EXCL | O_NOFOLLOW`
   relative to the folder opened without following symlinks, so a scan can
   never overwrite or be redirected onto another file. Each document is
   capped at 512 MB and replies from the scanner at 256 KB.

The scanner's TLS certificate is not checked: printers ship self-signed ones,
and the address comes from the local network's own announcement — the same
trust CUPS gives an IPPS printer it found that way.

## License

[MIT](LICENSE)
