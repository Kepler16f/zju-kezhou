param([string]$DocxPath, [string]$PdfPath)
$word = New-Object -ComObject Word.Application
$word.Visible = $false
try {
  $doc = $word.Documents.Open($DocxPath, $false, $true)
  $doc.SaveAs([ref]$PdfPath, [ref]17)  # wdFormatPDF = 17
  $doc.Close($false)
} finally {
  $word.Quit()
  [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($word)
}
Write-Output "PDF_DONE"
