$root = "C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid\media\lua"

$results = @()

Get-ChildItem -Path $root -Recurse -Filter *.lua | ForEach-Object {

    $file = $_
    $relative = $file.FullName.Substring($root.Length).TrimStart('\','/')

    if ($relative -match "^(client)[\\/]" ) {
        $scope = "client"
    }
    elseif ($relative -match "^(server)[\\/]" ) {
        $scope = "server"
    }
    else {
        $scope = "shared"
    }

    $lines = Get-Content $file.FullName

    foreach ($line in $lines) {

        # function name(...)
        if ($line -match "function\s+([A-Za-z0-9_]+)\s*\(") {
            $method = $matches[1]
        }

        # function Class:name(...)
        elseif ($line -match "function\s+([A-Za-z0-9_]+:[A-Za-z0-9_]+)\s*\(") {
            $method = $matches[1]
        }

        # function Class.name(...)
        elseif ($line -match "function\s+([A-Za-z0-9_.]+)\s*\(") {
            $method = $matches[1]
        }

        # name = function(...)
        elseif ($line -match "([A-Za-z0-9_]+)\s*=\s*function\s*\(") {
            $method = $matches[1]
        }

        # table.method = function(...)
        elseif ($line -match "([A-Za-z0-9_.]+)\s*=\s*function\s*\(") {
            $method = $matches[1]
        }

        # obj["method"] = function(...)
        elseif ($line -match "([A-Za-z0-9_]+)\s*\[\s*['""]([A-Za-z0-9_]+)['""]\s*\]\s*=\s*function") {
            $method = "$($matches[1]).$($matches[2])"
        }

        # obj[methodName] = function(...)  (méthode dynamique)
        elseif ($line -match "([A-Za-z0-9_]+)\s*\[\s*([A-Za-z0-9_]+)\s*\]\s*=\s*function") {
            $method = "$($matches[1]).[$($matches[2])]"
        }

        else {
            continue
        }

        $results += [PSCustomObject]@{
            scope = $scope
            file = $file.Name
            method = $method
        }
    }
}

# suppression des doublons
$results = $results | Sort-Object scope,file,method -Unique

# affichage console
$results | ForEach-Object {
    "$($_.scope),$($_.file),$($_.method)"
}

# export CSV
$results | Export-Csv "pz_lua_methods_full.csv" -NoTypeInformation