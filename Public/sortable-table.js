// Shared client-side column sorting for any <table class="sortable-table">.
//
// Conventions (matching the admin runner dashboard):
//   <table class="results-table sortable-table">
//     <thead><tr>
//       <th data-sort-type="text|number|date">
//         <button class="sort-header" type="button">Label</button>
//       </th> ...
//     </tr></thead>
//     <tbody><tr>
//       <td data-sort-value="<raw>">formatted</td> ...
//
// `data-sort-value` lets a cell sort by an underlying value (e.g. raw bytes
// behind "1.4 GB", or an ISO date behind "3 hours ago"); it falls back to the
// cell's text. Clicking a header toggles asc/desc; styling lives in styles.css
// (.sort-header, th.sort-asc, th.sort-desc).
(function () {
    'use strict';

    function compareValues(a, b, sortType) {
        if (sortType === 'number') {
            var aNum = Number(a);
            var bNum = Number(b);
            if (Number.isNaN(aNum) && Number.isNaN(bNum)) return 0;
            if (Number.isNaN(aNum)) return -1;
            if (Number.isNaN(bNum)) return 1;
            return aNum - bNum;
        }
        if (sortType === 'date') {
            var aDate = a ? new Date(a).getTime() : 0;
            var bDate = b ? new Date(b).getTime() : 0;
            return aDate - bDate;
        }
        return String(a).localeCompare(String(b), undefined, { numeric: true, sensitivity: 'base' });
    }

    function enhance(table) {
        var headers = Array.from(table.querySelectorAll('thead th'));
        var tbody = table.querySelector('tbody');
        if (!tbody) return;

        headers.forEach(function (th, index) {
            var button = th.querySelector('.sort-header');
            if (!button) return;

            button.addEventListener('click', function () {
                var nextDir = th.classList.contains('sort-asc') ? 'desc' : 'asc';
                headers.forEach(function (header) {
                    header.classList.remove('sort-asc', 'sort-desc');
                });
                th.classList.add(nextDir === 'asc' ? 'sort-asc' : 'sort-desc');

                var rows = Array.from(tbody.querySelectorAll('tr'));
                var sortType = th.getAttribute('data-sort-type') || 'text';
                rows.sort(function (rowA, rowB) {
                    var cellA = rowA.children[index];
                    var cellB = rowB.children[index];
                    var valueA = cellA ? (cellA.getAttribute('data-sort-value') || cellA.textContent || '') : '';
                    var valueB = cellB ? (cellB.getAttribute('data-sort-value') || cellB.textContent || '') : '';
                    var result = compareValues(valueA.trim(), valueB.trim(), sortType);
                    return nextDir === 'asc' ? result : -result;
                });
                rows.forEach(function (row) {
                    tbody.appendChild(row);
                });
            });
        });
    }

    function init() {
        document.querySelectorAll('.sortable-table').forEach(enhance);
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
