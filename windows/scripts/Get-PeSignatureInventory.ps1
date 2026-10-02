param(
    [Parameter(Mandatory)] [string] $Directory,
    [Parameter(Mandatory)] [string] $Output,
    [string] $SigningCatalog,
    [switch] $RequireValid
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $Directory).Path
function Has-EmbeddedSignature([string] $Path) {
    $stream = [IO.File]::OpenRead($Path)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($reader.ReadUInt16() -ne 0x5a4d) { throw "Not PE: $Path" }
        $stream.Position = 0x3c
        $pe = $reader.ReadUInt32()
        $stream.Position = $pe
        if ($reader.ReadUInt32() -ne 0x4550) { throw "Invalid PE: $Path" }
        $stream.Position = $pe + 24
        $directories = switch ($reader.ReadUInt16()) { 0x10b { 96 } 0x20b { 112 } default { throw 'Invalid PE optional header.' } }
        $stream.Position = $pe + 24 + $directories + 32
        $offset = $reader.ReadUInt32()
        $length = $reader.ReadUInt32()
        return $offset -gt 0 -and $length -ge 8 -and ($offset + [long]$length) -le $stream.Length
    } finally { $reader.Dispose(); $stream.Dispose() }
}
$inventory = @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Extension -in '.exe', '.dll' } | ForEach-Object {
    $file = $_
    $signature = Get-AuthenticodeSignature -LiteralPath $file.FullName
    $embedded = Has-EmbeddedSignature $file.FullName
    [pscustomobject]@{
        Path = [IO.Path]::GetRelativePath($root, $file.FullName)
        Sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        Status = "$($signature.Status)"
        SignatureType = "$($signature.SignatureType)"
        Embedded = $embedded
        Publisher = $signature.SignerCertificate.Subject
        Thumbprint = $signature.SignerCertificate.Thumbprint
        TimestampPublisher = $signature.TimeStamperCertificate.Subject
        Valid = $signature.Status -eq 'Valid' -and $embedded -and $null -ne $signature.TimeStamperCertificate
    }
})
if ($inventory.Count -eq 0) { throw 'No PE executables found.' }
$inventory | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Output -Encoding utf8
$invalid = @($inventory | Where-Object { -not $_.Valid })
if ($SigningCatalog) {
    $base = Split-Path -Parent $SigningCatalog
    $invalid | ForEach-Object { [IO.Path]::GetRelativePath($base, (Join-Path $root $_.Path)) } | Set-Content -LiteralPath $SigningCatalog -Encoding utf8
}
Write-Host "$($inventory.Count) PE files, $($invalid.Count) need signing. Inventory: $Output"
if ($RequireValid -and $invalid.Count) { throw "$($invalid.Count) PE files lack a valid timestamped embedded signature." }
