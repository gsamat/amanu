# The landing page

`https://samat.me/amanu/` — one page in English, the same page in Russian at
`ru/`, and nothing else: no build step, no dependencies, no web fonts, no
third-party script. It is served out of the same directory as `appcast.xml`,
which is the directory Sparkle asks for every day, so it has to keep working
when nothing else on the network does.

```
index.html      English
ru/index.html   Russian — same page, same order, translated rather than cut
amanu.css       the whole design; light and dark follow the reader's system
icon.png        512×512, from Resources/Amanu.icns
icon-180.png    the favicon and the touch icon
shots/{en,ru}/  the screenshots, one pair per window per appearance
```

The counter at the top of each page is the same first-party pixel as the rest
of samat.me: a `GET /m` that comes back as a 1×1 gif. Nobody else's code runs
on the page.

## Publishing

The site lives in the `gsamat/samatme3` checkout and is rsynced to the server —
the same two steps `scripts/release.sh` takes for the appcast, which it does
**not** do for this page. So publishing is by hand:

```sh
SITE=~/Documents/проекты/samatme3
rsync -a --exclude README.md site/ "$SITE/amanu/"
git -C "$SITE" add amanu && git -C "$SITE" commit -m "amanu: the landing page"
git -C "$SITE" push
rsync -az "$SITE/amanu/" reina:/var/www/samat/amanu/
```

`--exclude README.md` because this file is about the page, not part of it. The
trailing slashes matter, and `appcast.xml` is left alone: it is signed over the
exact bytes of a disk image, and this page never touches it.

The download button points at `releases/latest` rather than at a disk image,
because the image's name carries the version and the button would go stale at
every release.

## The screenshots

Made by the tool in `docs/testing/window-shots.md`, which renders amanu's own
windows to PNG:

```sh
mkdir -p /tmp/shots-en /tmp/shots-ru
AMANU_SHOTS=/tmp/shots-en swift test --filter WindowGallery
AMANU_SHOTS_LANGUAGE=ru AMANU_SHOTS=/tmp/shots-ru swift test --filter WindowGallery
```

Two things about those files decided what is on the page.

**The status window is cropped to its content.** Its title bar renders wrong in
the light appearance — the title is drawn at the left edge, clipped, over the
window buttons — and only there, and only for the recording state. The dark
one is correct, and so is every other window's. So both status shots have the
top 64 pixels cut off, which is what the diagnostic half of the same tool
produces anyway, and the window reads as a panel.

**The setup window is not on the page at all**, though it is the one that shows
what amanu asks you and what it found on the machine. Every `NSSwitch` in it
comes out in the off position whatever it is really set to — the caveat is in
`window-shots.md`, and it does not yield to anything. A picture of the setup
form with every switch apparently off is a picture of a program that does
nothing. That one has to be taken of the real application with `screencapture`.

The recordings window is posed: four sessions written into a folder of their
own for the exposure, so no real meeting's name is on the page. Everything else
in these pictures is this Mac saying what was true about it that day — which is
also why they are worth re-taking when the windows change, rather than kept in
step by hand.
