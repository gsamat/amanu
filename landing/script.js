// First-party analytics shared with the podcast site and CTOdaily. No
// third-party script: just a tracking-pixel request to this site's /m route.
(function () {
    var url = new URL('/m', location.origin);
    url.searchParams.set('p', location.pathname);
    url.searchParams.set('t', document.title);
    url.searchParams.set('s', [screen.width, screen.height, devicePixelRatio].join(','));
    if (document.referrer) url.searchParams.set('r', document.referrer);
    new Image().src = url;
})();

// Count release downloads as an aggregate site event. The request stays on
// the same first-party /m endpoint and does not share the app installation ID.
(function () {
    document.querySelectorAll('a[href*="/releases/download/"]').forEach(function (link) {
        link.addEventListener('click', function () {
            var url = new URL('/m', location.origin);
            url.searchParams.set('p', 'download_clicked');
            url.searchParams.set('t', 'Amanu download');
            url.searchParams.set('e', '1');
            url.searchParams.set('r', location.pathname);
            new Image().src = url;
        });
    });
})();

// Decorative recording timer. It stays still when reduced motion is enabled.
(function () {
    var el = document.getElementById('rec-time');
    if (!el || matchMedia('(prefers-reduced-motion: reduce)').matches) return;
    var seconds = 0;
    setInterval(function () {
        seconds += 1;
        var minutes = Math.floor(seconds / 60), remainder = seconds % 60;
        el.textContent = (minutes < 10 ? '0' + minutes : minutes)
            + ':' + (remainder < 10 ? '0' + remainder : remainder);
    }, 1000);
})();
