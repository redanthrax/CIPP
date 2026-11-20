function Unprotect-CIPPCloudBackupStream {
    <#
    .SYNOPSIS
        Decrypts a CIPPENC2 stream into another stream, fetching the key named in its header, and returns the number of bytes written.
    .DESCRIPTION
        Each chunk is verified before it is written. On a throw the output already holds the verified chunks before the
        damage, so callers must discard it.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.Stream]$InputStream,

        [Parameter(Mandatory = $true)]
        [System.IO.Stream]$OutputStream
    )

    $Header = [byte[]]::new(100)
    $HeaderLength = 0
    while ($HeaderLength -lt 100) {
        $Read = $InputStream.Read($Header, $HeaderLength, 100 - $HeaderLength)
        if ($Read -le 0) { break }
        $HeaderLength += $Read
    }
    if ($HeaderLength -lt 100 -or [System.Text.Encoding]::ASCII.GetString($Header, 0, 8) -ne 'CIPPENC2') {
        throw [System.ArgumentException]::new('The data is not in the CIPP cloud backup streaming encryption format.')
    }
    $ChunkSize = ([int]$Header[24] -shl 24) -bor ([int]$Header[25] -shl 16) -bor ([int]$Header[26] -shl 8) -bor [int]$Header[27]
    if ($ChunkSize -lt 1 -or $ChunkSize -gt 64MB) {
        throw [System.ArgumentException]::new('The data is not in the CIPP cloud backup streaming encryption format.')
    }

    $KeyIdBytes = [byte[]]::new(16)
    [System.Array]::Copy($Header, 8, $KeyIdBytes, 0, 16)
    $KeyId = [guid]::new($KeyIdBytes)
    $Key = Get-CIPPCloudBackupKey -KeyId $KeyId

    $WrapData = [byte[]]::new(28)
    $WrapNonce = [byte[]]::new(12)
    $WrappedKey = [byte[]]::new(32)
    $WrapTag = [byte[]]::new(16)
    [System.Array]::Copy($Header, 0, $WrapData, 0, 28)
    [System.Array]::Copy($Header, 28, $WrapNonce, 0, 12)
    [System.Array]::Copy($Header, 40, $WrappedKey, 0, 32)
    [System.Array]::Copy($Header, 72, $WrapTag, 0, 16)
    $DataKey = [byte[]]::new(32)
    $Damaged = "The backup data could not be decrypted with key $($KeyId): it has been changed or is damaged."

    $WrapCipher = [System.Security.Cryptography.AesGcm]::new($Key, 16)
    try {
        $WrapCipher.Decrypt($WrapNonce, $WrappedKey, $WrapTag, $DataKey, $WrapData)
    } catch [System.Security.Cryptography.CryptographicException] {
        throw $Damaged
    } finally {
        $WrapCipher.Dispose()
        [System.Array]::Clear($Key, 0, $Key.Length)
    }

    $DataCipher = [System.Security.Cryptography.AesGcm]::new($DataKey, 16)
    $Written = [long]0
    $Index = [uint64]0
    $Frame = [byte[]]::new($ChunkSize + 16)
    $Tag = [byte[]]::new(16)
    $Associated = [byte[]]::new(109)
    [System.Array]::Copy($Header, 0, $Associated, 0, 100)
    try {
        while ($true) {
            $FrameLength = 0
            while ($FrameLength -lt $Frame.Length) {
                $Read = $InputStream.Read($Frame, $FrameLength, $Frame.Length - $FrameLength)
                if ($Read -le 0) { break }
                $FrameLength += $Read
            }
            if ($FrameLength -lt 16) {
                throw "The backup data encrypted with key $($KeyId) is incomplete: it ends before its last chunk."
            }
            $Final = $FrameLength -lt $Frame.Length
            $PlainLength = $FrameLength - 16

            $Nonce = [byte[]]::new(12)
            [System.Array]::Copy($Header, 88, $Nonce, 0, 12)
            for ($i = 0; $i -lt 8; $i++) {
                $IndexByte = [byte](($Index -shr (8 * (7 - $i))) -band 0xFF)
                $Nonce[4 + $i] = $Nonce[4 + $i] -bxor $IndexByte
                $Associated[100 + $i] = $IndexByte
            }
            $Associated[108] = [byte]$(if ($Final) { 1 } else { 0 })

            $Ciphertext = [byte[]]::new($PlainLength)
            [System.Array]::Copy($Frame, 0, $Ciphertext, 0, $PlainLength)
            [System.Array]::Copy($Frame, $PlainLength, $Tag, 0, 16)
            $Plain = [byte[]]::new($PlainLength)
            try {
                $DataCipher.Decrypt($Nonce, $Ciphertext, $Tag, $Plain, $Associated)
            } catch [System.Security.Cryptography.CryptographicException] {
                throw $Damaged
            }
            $OutputStream.Write($Plain, 0, $PlainLength)
            $Written += $PlainLength
            $Index++

            if ($Final) {
                if ($InputStream.Read($Tag, 0, 1) -gt 0) { throw $Damaged }
                break
            }
        }
    } finally {
        $DataCipher.Dispose()
        [System.Array]::Clear($DataKey, 0, $DataKey.Length)
    }
    return $Written
}
