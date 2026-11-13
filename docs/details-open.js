// Opens every collapsed <details> block in the two cases where its text has to
// be visible without a click:
//
// - Printing. print.html holds the whole book, and a closed block prints as its
//   summary line alone.
// - Arriving from a search result. mdBook links a result with the matched terms
//   in a `highlight` query parameter and marks them in the page, and a term
//   inside a closed block would be marked where nobody can see it.
(function () {
    function openAll() {
        var blocks = document.querySelectorAll('.content details');
        for (var i = 0; i < blocks.length; i++) {
            blocks[i].open = true;
        }
    }

    function openForSearch() {
        if (/[?&]highlight=/.test(window.location.search)) {
            openAll();
        }
    }

    window.addEventListener('beforeprint', openAll);

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', openForSearch);
    } else {
        openForSearch();
    }
})();
