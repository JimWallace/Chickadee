(function (root, factory) {
    if (typeof module === 'object' && module.exports) {
        module.exports = factory();
    } else {
        root.ChickadeeSuiteList = factory();
    }
})(typeof self !== 'undefined' ? self : this, function () {
    'use strict';

    var SCRIPT_EXTS = ['sh','bash','zsh','py','r','rb','pl','js','php'];
    var BINARY_EXTS = ['exe','dll','so','dylib','class','jar','zip','tar','gz',
                       'png','jpg','jpeg','gif','bmp','svg','pdf','doc','docx',
                       'xls','xlsx','ppt','pptx','mp3','mp4','mov','avi'];

    function extensionOf(name) {
        var base = String(name || '').split('/').pop();
        var dot = base.lastIndexOf('.');
        return dot > 0 ? base.slice(dot + 1).toLowerCase() : '';
    }

    function isLikelyScriptName(name) {
        var ext = extensionOf(name);
        return SCRIPT_EXTS.indexOf(ext) >= 0;
    }

    function hasRecognizedScriptShebang(text) {
        var firstLine = String(text || '').split(/\r?\n/, 1)[0].trim().toLowerCase();
        if (firstLine.indexOf('#!') !== 0) return false;
        return /(^#!\s*\/.*\/(ba|z)?sh\b)|(^#!\s*\/usr\/bin\/env\s+(ba|z)?sh\b)|(^#!.*\bpython[0-9.]*\b)/.test(firstLine);
    }

    function classify(name, content, size) {
        var ext = extensionOf(name);
        var hasExt = ext.length > 0;
        var binary = BINARY_EXTS.indexOf(ext) >= 0;
        var scriptShebang = !hasExt && hasRecognizedScriptShebang(content || '');
        var isScript = isLikelyScriptName(name) || scriptShebang;
        var errs = [];
        if (binary) errs.push('Binary file — unlikely to work as a test script');
        if (!hasExt && !scriptShebang) {
            errs.push('No extension or recognized shebang; this file will be included as support unless marked as a test');
        }
        if (size === 0) errs.push('Empty file');
        return {
            isScript: isScript,
            tier: isScript ? 'public' : 'support',
            errors: errs
        };
    }

    function classifyFile(file) {
        if (!file) return Promise.resolve(classify('', '', 0));
        var ext = extensionOf(file.name);
        if (ext) return Promise.resolve(classify(file.name, '', file.size));
        var reader = typeof file.text === 'function'
            ? file.text()
            : Promise.resolve('');
        return reader
            .then(function (text) { return classify(file.name, text, file.size); })
            .catch(function () { return classify(file.name, '', file.size); });
    }

    function mergeFiles(existingFiles, selectedFiles) {
        var byName = {};
        var merged = [];
        function addOrReplace(file) {
            if (!file || !file.name) return;
            var idx = byName[file.name];
            if (idx === undefined) {
                byName[file.name] = merged.length;
                merged.push(file);
            } else {
                merged[idx] = file;
            }
        }
        (existingFiles || []).forEach(addOrReplace);
        (selectedFiles || []).forEach(addOrReplace);
        return merged;
    }

    function upsertUploadItems(items, files, classifications) {
        var nonUploads = (items || []).filter(function (it) { return it.source !== 'upload'; });
        var blocked = {};
        nonUploads.forEach(function (it) { blocked[it.name] = true; });

        var previousUploads = {};
        (items || []).forEach(function (it) {
            if (it.source === 'upload') previousUploads[it.name] = it;
        });

        var next = nonUploads.slice();
        (files || []).forEach(function (file, idx) {
            if (!file || !file.name || blocked[file.name]) return;
            var cls = (classifications && classifications[idx]) || (old ? {
                isScript: old.isTest,
                tier: old.tier,
                errors: old.errors || []
            } : classify(file.name, '', file.size));
            var old = previousUploads[file.name];
            next.push({
                name:        file.name,
                displayName: old ? old.displayName : '',
                source:      'upload',
                index:       idx,
                isTest:      old ? old.isTest : cls.isScript,
                tier:        old ? old.tier : cls.tier,
                dependsOn:   old ? old.dependsOn : [],
                points:      old ? old.points : 1,
                errors:      cls.errors
            });
        });
        return next;
    }

    return {
        classify: classify,
        classifyFile: classifyFile,
        hasRecognizedScriptShebang: hasRecognizedScriptShebang,
        isLikelyScriptName: isLikelyScriptName,
        mergeFiles: mergeFiles,
        upsertUploadItems: upsertUploadItems
    };
});
