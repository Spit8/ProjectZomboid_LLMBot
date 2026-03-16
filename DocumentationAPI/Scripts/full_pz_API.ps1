$root = "C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid\media\lua"

$classes = @{}
$methods = @()
$inheritance = @()
$events = @()
$calls = @()

function GetScope($path) {
    if ($path -match "[\\/]client[\\/]") { return "client" }
    elseif ($path -match "[\\/]server[\\/]") { return "server" }
    else { return "shared" }
}

Get-ChildItem $root -Recurse -Filter *.lua | ForEach-Object {

    $file = $_
    $scope = GetScope $file.FullName
    $lines = Get-Content $file.FullName

    foreach ($line in $lines) {

        $line = $line.Trim()

        # CLASS
        if ($line -match "^([A-Za-z0-9_]+)\s*=\s*{}") {

            $class = $matches[1]

            $classes[$class] = @{
                file = $file.Name
                scope = $scope
            }
        }

        # HERITAGE
        elseif ($line -match "^([A-Za-z0-9_]+)\s*=\s*([A-Za-z0-9_]+):derive") {

            $child = $matches[1]
            $parent = $matches[2]

            $inheritance += [PSCustomObject]@{
                child = $child
                parent = $parent
                file = $file.Name
            }
        }

        # METHOD Class:method
        elseif ($line -match "^function\s+([A-Za-z0-9_]+):([A-Za-z0-9_]+)") {

            $methods += [PSCustomObject]@{
                class = $matches[1]
                method = $matches[2]
                file = $file.Name
                scope = $scope
                type = "method"
            }
        }

        # STATIC METHOD Class.method
        elseif ($line -match "^function\s+([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)") {

            $methods += [PSCustomObject]@{
                class = $matches[1]
                method = $matches[2]
                file = $file.Name
                scope = $scope
                type = "static"
            }
        }

        # METHOD table.method = function
        elseif ($line -match "^([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)\s*=\s*function") {

            $methods += [PSCustomObject]@{
                class = $matches[1]
                method = $matches[2]
                file = $file.Name
                scope = $scope
                type = "method"
            }
        }

        # DYNAMIC METHOD ["name"]
        elseif ($line -match "^([A-Za-z0-9_]+)\[['""]([A-Za-z0-9_]+)['""]\]") {

            $methods += [PSCustomObject]@{
                class = $matches[1]
                method = $matches[2]
                file = $file.Name
                scope = $scope
                type = "dynamic"
            }
        }

        # EVENT
        elseif ($line -match "Events\.([A-Za-z0-9_]+)\.Add") {

            $events += [PSCustomObject]@{
                event = $matches[1]
                file = $file.Name
                scope = $scope
            }
        }

        # METHOD CALL detection
        elseif ($line -match "([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)\(") {

            $calls += [PSCustomObject]@{
                class = $matches[1]
                method = $matches[2]
                file = $file.Name
            }
        }
    }
}

# Nettoyage
$methods = $methods | Sort-Object class,method,file -Unique
$inheritance = $inheritance | Sort-Object child,parent -Unique
$events = $events | Sort-Object event,file -Unique
$calls = $calls | Sort-Object class,method,file -Unique

# Export CSV
$methods | Export-Csv "pz_methods.csv" -NoTypeInformation
$inheritance | Export-Csv "pz_inheritance.csv" -NoTypeInformation
$events | Export-Csv "pz_events.csv" -NoTypeInformation
$calls | Export-Csv "pz_calls.csv" -NoTypeInformation

Write-Host "Analyse terminée"
Write-Host "Classes:" $classes.Count
Write-Host "Methods:" $methods.Count
Write-Host "Events:" $events.Count
Write-Host "Calls:" $calls.Count