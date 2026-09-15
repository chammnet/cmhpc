Function Get-RandomPassword {
	<#
	.SYNOPSIS
	PowerShell random password generator
	.DESCRIPTION
	Generates one or more passwords based on user specified parameters.
	.PARAMETER Length
	Specify the length of the random password
	.PARAMETER Count
	Specify the number of passwords generated
	.PARAMETER Upper
	Switch to add uppercase letters A-Z
	.PARAMETER Lower
	Switch to add lowercase letters a-z
	.PARAMETER Numbers
	Switch to add numbers 0-9
	.PARAMETER Punctuation
	Switch to add punctuation !#$%&*+-?@^_~
	.PARAMETER Brackets
	Switch to add brackets ()<>[]{}
	.PARAMETER ExtraAscii
	Switch to add remaining low ASCII characters "',./:;\`|
	.PARAMETER IncludeChars
	Switch to include any string of characters. If you run into problems, enclose string in quotes.
	.PARAMETER ExcludeChars
	Switch to exclude any string of characters. If you run into problems, enclose string in quotes.
	.PARAMETER ExcludeAmbiguous
	Switch to exclude ambiguous characters !`"`'-125680ABDGIOQSZ^_``l|
	.PARAMETER AllAscii
	Switch to include all standard printable ASCII characters (033-126)
	.INPUTS
	Switches and parameters to generate desired password
	.OUTPUTS
	One or more random password based on the parameters
	.EXAMPLE
	Get-RandomPassword -Length 20 -Count 3 -Upper -Lower -Numbers -ExcludeChars "O0l1iI"
	Generates a list of three 20-character passwords, including uppercase, lowercase, numbers, but excluding the characters O0l1iI
	.EXAMPLE
	Get-RandomPassword -IncludeChars "ABCDEF1234567890"
	Generates a single 15-character password using only hex values
	.NOTES
	Written By: Craig Hamm 2016-08-08

	This function will generate random passwords using the Get-Random cmdlet, drawn from specified characters. If no parameters are specified, it will generate a 15-character secure password using most printable ASCII characters.

	Note that if the "IncludeChars" parameter is specificed, it will include ONLY those characters, unless other switches (Upper, Lower, Numbers) are specified.

	ExcludeChars parameter is processed last, so if you include and exclude the same character, it will be excluded from the password list.
	#>
	Param(
		[Parameter()]
		[Int]$Length = 15,

		[Parameter()]
		[Int]$Count = 1,

		[Parameter()]
		[Switch]$Upper,

		[Parameter()]
		[Switch]$Lower,

		[Parameter()]
		[Switch]$Numbers,

		[Parameter()]
		[Switch]$Punctuation,

		[Parameter()]
		[Switch]$Brackets,

		[Parameter()]
		[Switch]$Hex,

		[Parameter()]
		[Switch]$ExtraAscii,

		[Parameter()]
		[String]$IncludeChars,

		[Parameter()]
		[String]$ExcludeChars,

		[Parameter()]
		[Switch]$ExcludeAmbiguous,

		[Parameter()]
		[Switch]$AllAscii

	)

	$chars = New-Object System.Collections.ArrayList

	If ( $AllAscii ) {
		$Upper = $true
		$Lower = $true
		$Numbers = $true
		$Punctuation = $true
		$Brackets = $true
		$ExtraAscii = $true
	}

	If ( $ExcludeAmbiguous ) {
		$ExcludeChars = $ExcludeChars + "!`"'-125680ABDGIOQSZ^_``l|"
	}
	If ($Hex) {
		$IncludeChars = $IncludeChars + "0123456789abcdef"
	}

	If ( $Upper ) {
		( 65..90 ) | ForEach-Object { $chars.Add( $_ ) } | Out-Null
	}
	If ( $Lower ) {
		( 97..122 ) | ForEach-Object { $chars.Add( $_ ) } | Out-Null
	}
	If ( $Numbers ) {
		( 48..57 ) | ForEach-Object { $chars.Add( $_ ) } | Out-Null
	}
	If ( $Punctuation ) {
		( 33, 35, 36, 37, 38, 42, 43, 45, 61, 63, 64, 94, 95, 126 ) | ForEach-Object { $chars.Add( $_ ) } | Out-Null
	}
	If ( $Brackets ) {
		( 40, 41, 60, 62, 91, 93, 123, 125 ) | ForEach-object { $chars.Add( $_ ) } | Out-Null
	}
	If ( $ExtraASCII ) {
		( 34, 39, 44, 46, 47, 58, 59, 92, 96, 124 ) | ForEach-Object { $chars.Add( $_ ) } | Out-Null
	}

	#Include specific characters from passwords
	$IncludeChars.ToCharArray() | ForEach-Object { $chars.Add( [Int][Char]$_ ) } | Out-Null

	# Set a default character set if none is specified
	If ( -not $chars ) {
		( 65..90 ) | ForEach-Object { $chars.Add( $_ ) } | Out-Null
		( 97..122 ) | ForEach-Object { $chars.Add( $_ ) } | Out-Null
		( 48..57 ) | ForEach-Object { $chars.Add( $_ ) } | Out-Null
		( 33, 35, 36, 37, 38, 42, 43, 45, 61, 63, 64, 94, 95, 126 ) | ForEach-Object { $chars.Add( $_ ) } | Out-Null
	}

	$chars = [System.Collections.ArrayList]( $chars | Sort-Object -Unique )

	#Exclude specific characters from passwords
	$ExcludeChars.ToCharArray() | ForEach-Object { $chars.Remove( [Int][Char]$_ ) } | Out-Null

	For ( $o = 0; $o -lt $Count; $o++ ) {
		$RandPW = New-Object System.Collections.ArrayList
		For ( $i = 0; $i -lt $Length; $i++ ) {
			$RandPW.Add( [char]( $chars | Get-Random ) ) | Out-Null
		}
		Write-Host -foregroundcolor white -backgroundcolor blue ( ( $RandPW -join "") + "`e[0m" )
	}
} # End function Get-RandomPassword
