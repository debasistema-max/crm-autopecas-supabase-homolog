param(
  [Parameter(Mandatory = $true)]
  [string]$Path,
  [int]$PreviewRows = 8,
  [int]$PreviewColumns = 40
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Read-ZipEntryText {
  param([System.IO.Compression.ZipArchive]$Archive, [string]$EntryName)
  $entry = $Archive.GetEntry($EntryName)
  if ($null -eq $entry) { return $null }
  $reader = [System.IO.StreamReader]::new($entry.Open())
  try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Get-CellColumnNumber {
  param([string]$Reference)
  $letters = ([regex]::Match($Reference, '^[A-Z]+')).Value
  $column = 0
  foreach ($letter in $letters.ToCharArray()) {
    $column = ($column * 26) + ([int][char]$letter - [int][char]'A' + 1)
  }
  return $column
}

function Get-CellText {
  param([System.Xml.XmlElement]$Cell, [string[]]$SharedStrings)
  $type = $Cell.GetAttribute('t')
  if ($type -eq 'inlineStr') {
    return (($Cell.SelectNodes(".//*[local-name()='t']") | ForEach-Object { $_.InnerText }) -join '')
  }
  $valueNode = $Cell.SelectSingleNode("./*[local-name()='v']")
  if ($null -eq $valueNode) { return '' }
  $raw = $valueNode.InnerText
  if ($type -eq 's' -and $raw -match '^\d+$') {
    $index = [int]$raw
    if ($index -ge 0 -and $index -lt $SharedStrings.Count) { return $SharedStrings[$index] }
  }
  if ($type -eq 'b') { return $(if ($raw -eq '1') { 'TRUE' } else { 'FALSE' }) }
  return $raw
}

$resolvedPath = (Resolve-Path -LiteralPath $Path).Path
$archive = [System.IO.Compression.ZipFile]::OpenRead($resolvedPath)
try {
  [xml]$workbookXml = Read-ZipEntryText $archive 'xl/workbook.xml'
  [xml]$relationshipsXml = Read-ZipEntryText $archive 'xl/_rels/workbook.xml.rels'
  $sharedStrings = @()
  $sharedXmlText = Read-ZipEntryText $archive 'xl/sharedStrings.xml'
  if ($sharedXmlText) {
    [xml]$sharedXml = $sharedXmlText
    $sharedStrings = @($sharedXml.SelectNodes("//*[local-name()='si']") | ForEach-Object {
      (($_.SelectNodes(".//*[local-name()='t']") | ForEach-Object { $_.InnerText }) -join '')
    })
  }

  $relationships = @{}
  foreach ($relationship in $relationshipsXml.SelectNodes("//*[local-name()='Relationship']")) {
    $target = $relationship.GetAttribute('Target') -replace '^/', ''
    if (-not $target.StartsWith('xl/')) { $target = 'xl/' + $target.TrimStart('/') }
    $relationships[$relationship.GetAttribute('Id')] = $target
  }

  $sheetResults = @()
  foreach ($sheet in $workbookXml.SelectNodes("//*[local-name()='sheet']")) {
    $relationshipId = $sheet.GetAttribute('id', 'http://schemas.openxmlformats.org/officeDocument/2006/relationships')
    $entryName = $relationships[$relationshipId]
    $sheetXmlText = Read-ZipEntryText $archive $entryName
    [xml]$sheetXml = $sheetXmlText
    $rows = $sheetXml.SelectNodes("//*[local-name()='sheetData']/*[local-name()='row']")
    $preview = @()
    foreach ($row in $rows) {
      $values = [ordered]@{}
      foreach ($cell in $row.SelectNodes("./*[local-name()='c']")) {
        $column = Get-CellColumnNumber $cell.GetAttribute('r')
        if ($column -le $PreviewColumns) {
          $text = Get-CellText $cell $sharedStrings
          $formulaNode = $cell.SelectSingleNode("./*[local-name()='f']")
          if ($text -ne '' -or $null -ne $formulaNode) {
            $values[$cell.GetAttribute('r')] = [ordered]@{
              value = $text
              formula = $(if ($formulaNode) { $formulaNode.InnerText } else { $null })
            }
          }
        }
      }
      if ($values.Count -gt 0) {
        $preview += [ordered]@{ row = [int]$row.GetAttribute('r'); cells = $values }
        if ($preview.Count -ge $PreviewRows) { break }
      }
    }
    $dimension = $sheetXml.SelectSingleNode("//*[local-name()='dimension']")
    $sheetResults += [ordered]@{
      name = $sheet.GetAttribute('name')
      entry = $entryName
      dimension = $(if ($dimension) { $dimension.GetAttribute('ref') } else { $null })
      row_nodes = $rows.Count
      formula_cells = ([regex]::Matches($sheetXmlText, '<f(?:\s|>)')).Count
      preview = $preview
    }
  }

  [ordered]@{
    path = $resolvedPath
    size = (Get-Item -LiteralPath $resolvedPath).Length
    shared_strings = $sharedStrings.Count
    sheets = $sheetResults
  } | ConvertTo-Json -Depth 12
} finally {
  $archive.Dispose()
}
