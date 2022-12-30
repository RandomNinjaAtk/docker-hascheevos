#!/usr/bin/env bash
scriptVersion="2"

######### DEBUGGING
#raUsername=
#raWebApiKey=
libraryPath="/roms"
consoles="fds,pc88,pcfx,pcenginecd,fbneo,apple2,supervision,wasm4,megaduck,arduboy,channelf,atarist,c64,zxspectrum,x68000,pcengine,o2em,msx2,msx1,ngp,ngpc,amstradcpc,lynx,jaguar,atari2600,atari5200,vectrex,intellivision,wswan,wswanc,atari7800,colecovision,sg1000,virtualboy,pokemini,gamegear,gb,gbc,gba,nds,,nes,snes,megadrive,mastersystem,sega32x,3do,n64,psp,segacd,saturn,psx,dreamcast,ps2"
#consoles=psp
######### LOGGING

# auto-clean up log file to reduce space usage
if [ -f "/config/log.txt" ]; then
  find /config -type f -iname "log.txt" -size +1024k -delete
fi

touch "/config/log.txt"
exec &> >(tee -a "/config/log.txt")

######### FUNCTIONS

Log () {
  m_time=`date "+%F %T"`
  echo $m_time" :: RA-Rom-Processor :: $scriptVersion :: $consoleProcessNumber/$consolesToProcessNumber :: $consoleName ($consoleFolder) :: $currentsubprocessid/$totalCount :: "$1
}

DownloadFile () {
  # $1 = URL
  # $2 = Output Folder/file
  # $3 = Number of concurrent connections to use
  # $4 = fileName
  Log "Downloading :: $4"
  axel -n $ConcurrentDownloadThreads --output="$2" "$1" | awk -W interactive '$0~/\[/{printf "%s'$'\r''", $0}'
  #wget -q --show-progress --progress=bar:force 2>&1 "$1" -O "$2"
  if [ ! -f "$2" ]; then
    Log "Download Failed :: $1"
  fi
  if [ -f "$2" ]; then
    chmod 666 "$2"
  fi
}

DownloadFileVerification () {
  Log "$1 :: Verifing Download..."
  case "$1" in
    *.zip|*.ZIP)
      verify="$(unzip -t "$1" &>/dev/null; echo $?)"
      ;;
    *.rar|*.RAR)
      verify="$(unrar t "$1" &>/dev/null; echo $?)"
      ;;
    *.7z|*.7Z)
      verify="$(7z t "$1" &>/dev/null; echo $?)"
      ;;
    *.chd|*.CHD)
      verify="$(chdman verify -i "$1" &>/dev/null; echo $?)"
      ;;
    *.iso|*.ISO|*.hex|*.HEX|*.wasm|*.WASM|*.sv|*.SV)
      Log "No methdod to verify this type of file (iso,hex,wasm,sv)"
      verify="0"
      ;;
  esac
  
  if [ "$verify" != "0" ]; then
    Log "$1 :: ERROR :: Failed Verification!"
    rm "$1"
  else
    Log "$1 :: Download Verified!"
  fi
}

UncompressFile () {
  # $1 is input file
  # $2 is output folder
  Log "Uncompressing \"$1\" to \"$2\""
  case "$1" in
    *.zip|*.ZIP)
      Log "Zip file detected!"
      unzip -o -d "$2" "$1" >/dev/null
      ;;
    *.rar|*.RAR)
      Log "Rar file detected!"
      unrar x "$1" "$2" &>/dev/null
      ;;
    *.7z|*.7Z)
      Log "7z file detected!"
      7z e "$1" -o"$2" &>/dev/null
      ;;
  esac
  Log "Uncompressing Complete!"
  rm "$1"
}

CompressFile () {
  # $1 is input file
  # $2 is output file
  Log "Compress \"$1\" to \"$2\""
  zip -mj "$2" "$1" >/dev/null  
  Log "Compressing Complete!"
}

RaHashRom (){
  # $1 = ROM file
  # $2 = Console ID
  raHash=""
  Log "$1 :: Hashing..."
  raHash=$(/usr/local/RALibretro/bin64/RAHasher $2 "$1") || ret=1
  Log "$1 :: Hash Found :: $raHash"
}

DownloadRaHashLibrary () {
  # $1 = raConsoleId
  # $2 = consoleFolder

  # create hash library folder
  if [ ! -d /config/ra_hash_libraries ]; then
    mkdir -p /config/ra_hash_libraries
    chmod 777 /config/ra_hash_libraries    
  fi
  if [ -f "/config/ra_hash_libraries/${2}_hashes.json" ]; then
    rm "/config/ra_hash_libraries/${2}_hashes.json"
  fi

  Log "Getting the console hash library from RetroAchievements.org..."
  if [ ! -f "/config/ra_hash_libraries/${2}_hashes.json" ]; then
    curl -s "https://retroachievements.org/dorequest.php?r=hashlibrary&c=$1" | jq '.' > "/config/ra_hash_libraries/${2}_hashes.json"
    chmod 666 "/config/ra_hash_libraries/${2}_hashes.json"
  fi
  Log "Done"
}

RomRaHashVerification () {
  # $1 = romFile
  # $2 = consoleFolder
  raGameId=""
  Log "$1 :: Matching To RetroAchievements.org DB"
  if cat "/config/ra_hash_libraries/${2}_hashes.json" | jq -r .[] | grep -i "\"$raHash\"" | read; then
    raGameId=$(cat "/config/ra_hash_libraries/${2}_hashes.json" | jq -r .[] | grep -i "\"$raHash\"" | cut -d ":" -f 2 | sed "s/\ //g" | sed "s/,//g")
    Log "$1 :: Match Found :: Game ID :: $raGameId"
    if [ ! -d "/config/logs/$2/matched" ]; then
      mkdir -p "/config/logs/$2/matched"
      chmod 777 "/config/logs/$consoleFolder/matched"
    fi
    touch "/config/logs/$2/matched/${raGameId}_ra_game_id"
    chmod 666 "/config/logs/$2/matched/${raGameId}_ra_game_id"
  else
    Log "$1 :: ERROR :: Not Found on RetroAchievements.org DB"
    rm "$1"
  fi
}

MoveRomToFinalLocation () {
  # $1 = romFile
  # $2 = Destination
  if [ ! -d "$2" ]; then
    Log "Creating $2"
    mkdir -p "$2"
    chmod 777 "$2"
    Log "Done"
  fi
  outputFile=""
  outputFile="$2/$(basename "$romFile")"
  if [ ! -f "$outputFile" ]; then
    Log "$1 :: Moving file to: $outputFile"
    mv "$1" "$outputFile"
    chmod 666 "$outputFile"
    Log "Done"
  fi
}


UrlDecode () { : "${*//+/ }"; echo -e "${_//%/\\x}"; }

Skraper () {
  # $1 - CosoleFolder
  # $2 - Output folder
  # #3 - Skyskarper platform name 

  if [ "$ScrapeMetadata" = "true" ]; then
		if Skyscraper | grep -w "$1" | read; then
			Log "Begin Skyscraper Process..."
			if find /output/$folder -type f | read; then
				Log "Checking For ROMS in $2 :: ROMs found, processing..."
			else
				echo "Checking For ROMS in $2 :: No ROMs found, skipping..."
				continue
			fi
			# Scrape from screenscraper
			if [ "$compressRom" == "true" ]; then
				Skyscraper -f emulationstation -u $ScreenscraperUsername:$ScreenscraperPassword -p $1 -d /cache/$1 -s screenscraper -i "$2" --flags relative,videos,unattend,nobrackets,unpack
			else
				Skyscraper -f emulationstation -u $ScreenscraperUsername:$ScreenscraperPassword -p $1 -d /cache/$1 -s screenscraper -i "$2" --flags relative,videos,unattend,nobrackets
			fi
			# Save scraped data to output folder
			Skyscraper -f emulationstation -p $1 -d /cache/$1 -i "$2" --flags relative,videos,unattend,nobrackets
			# Remove skipped roms
			if [ -f /root/.skyscraper/skipped-$1-cache.txt ]; then
				cat /root/.skyscraper/skipped-$1-cache.txt | while read LINE;
				do 
					rm "$LINE"
				done
			fi
		else 
			Log "Metadata Scraping :: ERROR :: Platform not supported, skipping..."
		fi 
	else
		Log "Metadata Scraping disabled..."
		Log "Enable by setting \"ScrapeMetadata=true\""
	fi

}

######### PROCESS
currentsubprocessid=0
totalCount=0

if [ ! -d /config/consoles ]; then
  mkdir -p /config/consoles
  chmod 777 /config/consoles
fi

consolesToProcessNumber=0
IFS=',' read -r -a filters <<< "$consoles"
for console in "${filters[@]}"
do
  consolesToProcessNumber=$(( $consolesToProcessNumber + 1 ))
done

consoleProcessNumber=0
IFS=',' read -r -a filters <<< "$consoles"
for console in "${filters[@]}"
do
  consoleProcessNumber=$(( $consoleProcessNumber + 1 ))
  consoleName="Unknown"
  consoleFolder="unk"
  downloadAll="false"

  consoleFile="/config/consoles/$console.sh"
  if [ ! -f "$consoleFile" ]; then
    consoleFile=/consoles/$console.sh
  fi

  if [ ! -f "$consoleFile" ]; then
    Log "ERROR :: Console Data File ($consoleFile) Missing..."
    continue
  fi

  source $consoleFile

  if [ -z "$raUsername" ] || [ -z "$raWebApiKey" ]; then
    Log "ERROR :: raUsername & raWebApiKey not set, exiting..."
    exit
  fi
  
  raGameTitlesCount=0
  raGameList="$(wget -qO- "https://retroachievements.org/API/API_GetGameList.php?z=${raUsername}&y=${raWebApiKey}&i=$raConsoleId")"
  raGameTitles=$(echo "$raGameList" | jq -r .[].Title | sort -u)
  raGameTitlesCount=$(echo -n "$raGameTitles" | wc -l)
  if [ -d $libraryPath/temp ]; then
    rm -rf $libraryPath/temp
  fi

  if [ ! -d $libraryPath/temp ]; then
    mkdir -p $libraryPath/temp
  fi

  DownloadRaHashLibrary "$raConsoleId" "$consoleFolder"

  if cat "/config/ra_hash_libraries/${consoleFolder}_hashes.json" | grep '"MD5List": \[\]' | read; then
    Log "ERROR :: No hashes found on RetroAchievements.org website for this console..."
    Log "Skipping..."
    continue
  fi

  totalCount="$(echo "$archiveUrl" | wc -l)"
  OLDIFS="$IFS"
  IFS=$'\n'
  archiveUrls=($(echo "$archiveUrl" | sort -ur))
  IFS="$OLDIFS"
  for Url in ${!archiveUrls[@]}; do
    currentsubprocessid=$(( $Url + 1 ))
    downloadUrl="${archiveUrls[$Url]}"
    decodedUrl="$(UrlDecode "$downloadUrl")"
    fileName="$(basename "$decodedUrl")"
    fileNameNoExt="${fileName%.*}"
    fileNameSearch=$(echo "$fileNameNoExt"| cut -f1 -d"(" | sed "s/\ $//g" )
    fileNameFirstWord="$(echo "$fileNameSearch"  | awk '{ print $1 }')"
    fileNameFirstWordClean=$(echo "$fileNameFirstWord" | sed -e "s%[^[:alpha:][:digit:]]%%g" -e "s/  */ /g" | sed 's/^[.]*//' | sed  's/[.]*$//g' | sed  's/^ *//g' | sed 's/ *$//g')
    fileNameFirstWordClean="${fileNameFirstWordClean:0:10}"
    fileNameSecondWord="$(echo "$fileNameSearch"  | awk '{ print $2 }')"
    fileNameSecondWordClean=$(echo "$fileNameSecondWord" | sed -e "s%[^[:alpha:][:digit:]]%%g" -e "s/  */ /g" | sed 's/^[.]*//' | sed  's/[.]*$//g' | sed  's/^ *//g' | sed 's/ *$//g')
    fileNameSecondWordClean="${fileNameSecondWordClean:0:10}"
    fileNameThirdWord="$(echo "$fileNameSearch"  | awk '{ print $2 }')"
    ffileNameThirdWordClean=$(echo "$fileNameThirdWord" | sed -e "s%[^[:alpha:][:digit:]]%%g" -e "s/  */ /g" | sed 's/^[.]*//' | sed  's/[.]*$//g' | sed  's/^ *//g' | sed 's/ *$//g')
    fileNameThirdWordClean="${ffileNameThirdWordClean:0:10}"
    raGameTitlesClean=$(echo "$raGameTitles" | sed -e "s%[^[:alpha:][:digit:]]%%g" -e "s/  */ /g" | sed 's/^[.]*//' | sed  's/[.]*$//g' | sed  's/^ *//g' | sed 's/ *$//g')
    #echo "$fileNameFirstWordClean $fileNameSecondWordClean"
    
    if [ "$downloadAll" == "false" ]; then
      if echo "${raGameTitlesClean,,}" | grep -i "${fileNameFirstWordClean,,}" | grep -i "${fileNameSecondWordClean,,}" | grep -i "${fileNameThirdWordClean,,}" | read; then
        Log "$fileNameNoExt :: Title found on RA Game List"
      else
        Log "$fileNameNoExt :: ERROR :: Title not found on RA Game List, skipping..."
        Log "$fileNameNoExt :: ERROR :: To download all roms, set \"downloadAll=true\" in file: $consoleFile"
        continue
      fi
    fi

    if [ -f "/config/logs/$consoleFolder/downloaded/$fileName.txt" ]; then
      Log "$fileNameNoExt :: Previously Processed..."
      continue
    fi
    if [ -d "$libraryPath/$consoleFolder" ]; then
      if find "$libraryPath/$consoleFolder" -type f -iname "$fileNameNoExt.*" | read; then
        Log "$libraryPath/$consoleFolder/$fileNameNoExt.* :: File already exists :: skipping..."
        if [ ! -d /config/logs/$consoleFolder ]; then
          mkdir -p /config/logs/$consoleFolder
          chmod 777 /config/logs/$consoleFolder
        fi
        if [ ! -d "/config/logs/$consoleFolder/downloaded" ]; then
          mkdir -p "/config/logs/$consoleFolder/downloaded"
          chmod 777 "/config/logs/$consoleFolder/downloaded"
        fi
        touch "/config/logs/$consoleFolder/downloaded/$fileName.txt"
        chmod 666 "/config/logs/$consoleFolder/downloaded/$fileName.txt"
        continue
      fi
    fi
    DownloadFile "$downloadUrl" "$libraryPath/temp/$fileName" "$concurrentDownloadThreads" "$fileName"

    if [ ! -f "$libraryPath/temp/$fileName" ]; then
      Log "$fileNameNoExt :: Skipping..."
      continue
    else
      mkdir -p "/config/logs/$consoleFolder"
       if [ ! -d "/config/logs/$consoleFolder/downloaded" ]; then
          mkdir -p "/config/logs/$consoleFolder/downloaded"
          chmod 777 "/config/logs/$consoleFolder/downloaded"
        fi
      touch "/config/logs/$consoleFolder/downloaded/$fileName.txt"
    fi
    DownloadFileVerification "$libraryPath/temp/$fileName"
    if [ ! -f "$libraryPath/temp/$fileName" ]; then
      Log "Skipping..."
      continue
    fi
    if [ "$uncompressRom" == "true" ]; then
      UncompressFile "$libraryPath/temp/$fileName" "$libraryPath/temp"
    fi
    romFile=$(find $libraryPath/temp -type f)
    romFileExt="${romFile##*.}"
    Log "Checking for Valid ROM extension"
    if ! echo "$consoleRomFileExt" | grep -E "\.$romFileExt(,|$)" | read; then
      Log "ERROR :: \"$consoleRomFileExt\" file extension(s) expected :: \"$romFileExt\" found..."
      Log "Skipping..."
      rm $libraryPath/temp/*
      continue
    else
      Log "Valid ROM extension found (.$romFileExt)"
    fi

    RaHashRom "$romFile" "$raConsoleId"
    RomRaHashVerification "$romFile" "$consoleFolder"
    if [ ! -f "$romFile" ]; then
      Log "Skipping..."
      continue
    fi
    if [ "$compressRom" == "true" ]; then
      CompressFile "$romFile" "$libraryPath/temp/$fileNameNoExt.zip"
    fi
    romFile=$(find $libraryPath/temp -type f)
    MoveRomToFinalLocation "$romFile" "$libraryPath/$consoleFolder"
    
    if [ -d $libraryPath/temp ]; then
      rm $libraryPath/temp/* &>/dev/null
    fi
    
  done
  if [ -d  "$libraryPath/$consoleFolder" ]; then
    downloadRomCount=$(find "$libraryPath/$consoleFolder" -maxdepth 1 -type f -not -iname "*.xml" | wc -l)
    matchedRomCount=$(find "/config/logs/$consoleFolder/matched" -type f | wc -l)
  else
    downloadRomCount=0
  fi
  Log "===================================================================="
  Log "Downloaded ($downloadRomCount) ROMs and matched $matchedRomCount of $raGameTitlesCount possible RetroAchievements.org ROMs"
  Log "Only $(( $raGameTitlesCount - $matchedRomCount)) ROMs missing..."
  Log "$(( $downloadRomCount - $matchedRomCount)) Duplicate ROMs found..."
  sleep 5
  if [ -d $libraryPath/temp ]; then
    rm -rf $libraryPath/temp
  fi

  if [ -d "$libraryPath/$consoleFolder" ]; then
    Skraper "$consoleFolder" "$libraryPath/$consoleFolder"
  fi
done

exit
