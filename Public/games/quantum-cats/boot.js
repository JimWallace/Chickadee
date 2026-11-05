'use strict';
  QCUI.init();
  QC.start(p => { document.getElementById('load-fill').style.width = Math.round(p * 100) + '%'; })
    .then(() => { document.getElementById('loading').hidden = true; QCUI.showMenu(); })
    .catch(e => { document.querySelector('.load-box').textContent = 'Could not load the game files. Make sure every file from the zip was extracted into the same folder, then reload.'; console.error(e); });
