/**
 * TAMBAHAN untuk Apps Script kamu (tempel di file baru, Kode.gs TIDAK diubah).
 * Tujuan: jembatan HTTP untuk APK KelontongPOS.
 *
 * CARA DEPLOY:
 * 1. Buka project Apps Script, tempel file ini.
 * 2. Deploy > New deployment > Web app
 *    - Execute as: Me
 *    - Who has access: Anyone
 * 3. Copy URL Web App, tempel di aplikasi (menu Sinkron & URL).
 */

function doPost(e) {
  try {
    const req = JSON.parse(e.postData.contents);
    const fn = req.fn;
    const args = req.args || [];

    const allowed = [
      'processMultiSale', 'processPurchase', 'processStockOpname', 'processExpense',
      'addNewProduct', 'addNewUnitToProduct', 'updateSellingPrice',
      'saveRawSheetData', 'getRawSheetData',
      'getDashboardSummary', 'getActiveProductsList', 'getFilteredFinancialReport',
      'getDailyOmzetData', 'getStockLedgerData', 'checkProductExists'
    ];
    if (allowed.indexOf(fn) === -1) {
      throw new Error('Fungsi tidak diizinkan: ' + fn);
    }

    const result = this[fn].apply(null, args);
    return ContentService.createTextOutput(JSON.stringify({ ok: true, result: result }))
      .setMimeType(ContentService.MimeType.JSON);
  } catch (err) {
    return ContentService.createTextOutput(JSON.stringify({ ok: false, error: err.message }))
      .setMimeType(ContentService.MimeType.JSON);
  }
}

// Untuk tes cepat di browser: buka .../exec?fn=getDashboardSummary
function doGet(e) {
  if (e && e.parameter && e.parameter.fn) {
    try {
      const fn = e.parameter.fn;
      const allowed = ['getDashboardSummary', 'getActiveProductsList', 'getDailyOmzetData', 'getStockLedgerData', 'getFilteredFinancialReport', 'checkProductExists', 'getRawSheetData'];
      if (allowed.indexOf(fn) !== -1) {
        const args = e.parameter.args ? JSON.parse(e.parameter.args) : [];
        const result = this[fn].apply(null, args);
        return ContentService.createTextOutput(JSON.stringify({ ok: true, result: result }))
          .setMimeType(ContentService.MimeType.JSON);
      }
    } catch (err) {
      return ContentService.createTextOutput(JSON.stringify({ ok: false, error: err.message }))
        .setMimeType(ContentService.MimeType.JSON);
    }
  }
  return ContentService.createTextOutput('KelontongPOS Web App aktif. Gunakan aplikasi Android untuk akses.');
}
