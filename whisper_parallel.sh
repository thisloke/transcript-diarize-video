#!/bin/bash

# Load environment variables from .env file
if [ -f .env ]; then
  echo "Loading environment variables from .env file..."
  set -o allexport
  source .env
  set +o allexport
else
  echo "Warning: .env file not found. Using default values."
fi

# === CONFIGURAZIONE ===
# These defaults will be used if not set in .env file
KEY_NAME=${KEY_NAME:-"whisper-key"}
KEY_FILE=${KEY_FILE:-"$HOME/.ssh/${KEY_NAME}.pem"}
SECURITY_GROUP=${SECURITY_GROUP:-"whisper-sg"}
INSTANCE_TYPE=${INSTANCE_TYPE:-"g4dn.12xlarge"}  # Default a 1 GPU per rispettare limiti vCPU
REGION=${REGION:-"eu-south-1"}
AMI_ID=${AMI_ID:-"ami-059603706d3734615"}
VIDEO_FILE=${VIDEO_FILE:-"mio_video.mp4"}
ORIGINAL_FILENAME=$(basename "$VIDEO_FILE" | cut -d. -f1)
START_MIN=${START_MIN:-0}      # Default value if not set
END_MIN=${END_MIN:-0}        # Default value if not set
SHIFT_SECONDS=${SHIFT_SECONDS:-0}  # Shift timestamps by this many seconds
SHIFT_ONLY=${SHIFT_ONLY:-false}   # Set to true to only perform shifting on existing files
INPUT_PREFIX=${INPUT_PREFIX:-""}   # Prefix for input files when using SHIFT_ONLY
GPU_COUNT=${GPU_COUNT:-1}      # Numero di GPU da utilizzare (default: 1)
NUM_SPEAKERS=${NUM_SPEAKERS:-""}  # Numero di speaker se conosciuto (opzionale)
FIX_START=${FIX_START:-"true"}  # Aggiunge silenzio all'inizio per catturare i primi secondi

# === FUNZIONE PER SHIFT DEI TIMESTAMPS ===
shift_timestamps() {
    local input_file=$1
    local output_file=$2
    local shift_by=$3
    local file_ext="${input_file##*.}"

    if [ "$file_ext" = "srt" ]; then
        echo "🕒 Shifting SRT timestamps by $shift_by seconds..."
        # SRT format: 00:00:05,440 --> 00:00:08,300
        awk -v shift=$shift_by '
        function time_to_seconds(time_str) {
            split(time_str, parts, ",")
            split(parts[1], time_parts, ":")
            return time_parts[1]*3600 + time_parts[2]*60 + time_parts[3] + parts[2]/1000
        }

        function seconds_to_time(seconds) {
            h = int(seconds/3600)
            m = int((seconds-h*3600)/60)
            s = int(seconds-h*3600-m*60)
            ms = int((seconds - int(seconds))*1000)
            return sprintf("%02d:%02d:%02d,%03d", h, m, s, ms)
        }

        {
            if (match($0, /^([0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3}) --> ([0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3})$/)) {
                start_time = time_to_seconds(substr($0, RSTART, RLENGTH/2-5))
                end_time = time_to_seconds(substr($0, RSTART+RLENGTH/2+5, RLENGTH/2-5))

                new_start = start_time + shift
                new_end = end_time + shift

                # Handle negative times (not allowed in SRT)
                if (new_start < 0) new_start = 0
                if (new_end < 0) new_end = 0

                print seconds_to_time(new_start)" --> "seconds_to_time(new_end)
            } else {
                print $0
            }
        }' "$input_file" > "$output_file"

    elif [ "$file_ext" = "vtt" ]; then
        echo "🕒 Shifting VTT timestamps by $shift_by seconds..."
        # VTT format: 00:00:05.440 --> 00:00:08.300
        awk -v shift=$shift_by '
        function time_to_seconds(time_str) {
            split(time_str, parts, ".")
            split(parts[1], time_parts, ":")
            return time_parts[1]*3600 + time_parts[2]*60 + time_parts[3] + parts[2]/1000
        }

        function seconds_to_time(seconds) {
            h = int(seconds/3600)
            m = int((seconds-h*3600)/60)
            s = int(seconds-h*3600-m*60)
            ms = int((seconds - int(seconds))*1000)
            return sprintf("%02d:%02d:%02d.%03d", h, m, s, ms)
        }

        {
            if (match($0, /^([0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}) --> ([0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3})$/)) {
                start_time = time_to_seconds(substr($0, RSTART, RLENGTH/2-5))
                end_time = time_to_seconds(substr($0, RSTART+RLENGTH/2+5, RLENGTH/2-5))

                new_start = start_time + shift
                new_end = end_time + shift

                # Handle negative times
                if (new_start < 0) new_start = 0
                if (new_end < 0) new_end = 0

                print seconds_to_time(new_start)" --> "seconds_to_time(new_end)
            } else {
                print $0
            }
        }' "$input_file" > "$output_file"

    elif [ "$file_ext" = "txt" ]; then
        echo "🕒 Shifting timestamps in TXT by $shift_by seconds..."
        # For text files, we need to handle timestamps in formats like [00:05.440]
        awk -v shift=$shift_by '
        function time_to_seconds(time_str) {
            # Remove brackets
            gsub(/[\[\]]/, "", time_str)

            # Check format - either MM:SS.mmm or HH:MM:SS.mmm
            if (split(time_str, parts, ":") == 2) {
                # MM:SS.mmm format
                mm = parts[1]
                split(parts[2], sec_parts, ".")
                ss = sec_parts[1]
                ms = sec_parts[2] ? sec_parts[2] : 0
                return mm*60 + ss + ms/1000
            } else {
                # HH:MM:SS.mmm format
                hh = parts[1]
                mm = parts[2]
                split(parts[3], sec_parts, ".")
                ss = sec_parts[1]
                ms = sec_parts[2] ? sec_parts[2] : 0
                return hh*3600 + mm*60 + ss + ms/1000
            }
        }

        function seconds_to_time(seconds) {
            h = int(seconds/3600)
            m = int((seconds-h*3600)/60)
            s = seconds-h*3600-m*60
            # Format with up to 3 decimal places for milliseconds
            if (h > 0) {
                return sprintf("[%02d:%02d:%05.3f]", h, m, s)
            } else {
                return sprintf("[%02d:%05.3f]", m, s)
            }
        }

        {
            line = $0
            # Match timestamps in the format [MM:SS.mmm] or [HH:MM:SS.mmm]
            while (match(line, /\[[0-9]+:[0-9]+(\.[0-9]+)?\]/) || match(line, /\[[0-9]+:[0-9]+:[0-9]+(\.[0-9]+)?\]/)) {
                time_str = substr(line, RSTART, RLENGTH)
                time_sec = time_to_seconds(time_str)

                new_time = time_sec + shift
                if (new_time < 0) new_time = 0

                new_time_str = seconds_to_time(new_time)

                # Replace the timestamp
                line = substr(line, 1, RSTART-1) new_time_str substr(line, RSTART+RLENGTH)
            }
            print line
        }' "$input_file" > "$output_file"
    else
        echo "⚠️ Unsupported file extension for shifting: $file_ext"
        cp "$input_file" "$output_file"
    fi
}

# If we're only shifting timestamps, do that and exit
if [ "$SHIFT_ONLY" = "true" ]; then
    if [ -z "$INPUT_PREFIX" ]; then
        echo "❌ ERROR: When using SHIFT_ONLY=true, you must specify INPUT_PREFIX"
        exit 1
    fi

    echo "🕒 Performing timestamp shifting by $SHIFT_SECONDS seconds..."

    # Process each file type
    for ext in txt srt vtt; do
        # Check for regular transcript
        if [ -f "${INPUT_PREFIX}.${ext}" ]; then
            shift_timestamps "${INPUT_PREFIX}.${ext}" "${INPUT_PREFIX}_shifted.${ext}" $SHIFT_SECONDS
            echo "✅ Created ${INPUT_PREFIX}_shifted.${ext}"
        fi

        # Check for final transcript
        if [ -f "${INPUT_PREFIX}_final.${ext}" ]; then
            shift_timestamps "${INPUT_PREFIX}_final.${ext}" "${INPUT_PREFIX}_final_shifted.${ext}" $SHIFT_SECONDS
            echo "✅ Created ${INPUT_PREFIX}_final_shifted.${ext}"
        fi
    done

    echo "✅ Timestamp shifting complete!"
    exit 0
fi

# Generate random suffix
if command -v openssl > /dev/null 2>&1; then
    RANDOM_SUFFIX=$(openssl rand -hex 4)
elif command -v md5sum > /dev/null 2>&1; then
    RANDOM_SUFFIX=$(date +%s | md5sum | head -c 8)
elif command -v shasum > /dev/null 2>&1; then
    RANDOM_SUFFIX=$(date +%s | shasum | head -c 8)
else
    RANDOM_SUFFIX=$RANDOM$RANDOM
fi

AUDIO_FILE="${ORIGINAL_FILENAME}_${START_MIN}_${END_MIN}_${RANDOM_SUFFIX}.wav"
DIARIZATION_ENABLED=${DIARIZATION_ENABLED:-true}
HF_TOKEN=${HF_TOKEN:-""}
BUCKET_NAME=${BUCKET_NAME:-"whisper-video-transcripts"}

# Output file names with the same format
TRANSCRIPT_PREFIX="${ORIGINAL_FILENAME}_${START_MIN}_${END_MIN}_${RANDOM_SUFFIX}"
TRANSCRIPT_FILE="${TRANSCRIPT_PREFIX}.txt"
FINAL_TRANSCRIPT_FILE="${TRANSCRIPT_PREFIX}_final.txt"
SRT_FILE="${TRANSCRIPT_PREFIX}.srt"
VTT_FILE="${TRANSCRIPT_PREFIX}.vtt"

# === CONTROLLI PRELIMINARI ===
if [ ! -f "$KEY_FILE" ]; then
  echo "❌ Chiave SSH non trovata in $KEY_FILE"
  exit 1
fi
if [ ! -f "parallel_transcript.py" ]; then
  echo "❌ File parallel_transcript.py non trovato"
  exit 1
fi

if [ ! -f "$VIDEO_FILE" ]; then
  echo "❌ File video $VIDEO_FILE non trovato"
  exit 1
fi

# === CONVERTI MP4 IN WAV E APPLICA CROP PRIMA DELL'UPLOAD ===
echo "🎙️ Converto $VIDEO_FILE in $AUDIO_FILE con crop applicato..."
FFMPEG_CMD="ffmpeg -i \"$VIDEO_FILE\""

# Aggiungi parametri di crop se START_MIN o END_MIN sono impostati
if [ "$START_MIN" != "0" ] || [ "$END_MIN" != "0" ]; then
  START_SEC=$((START_MIN * 60))
  if [ "$END_MIN" != "0" ]; then
    END_SEC=$((END_MIN * 60))
    FFMPEG_CMD+=" -ss $START_SEC -to $END_SEC"
  else
    FFMPEG_CMD+=" -ss $START_SEC"
  fi
  echo "⏱️ Crop video da $START_MIN min a ${END_MIN:-fine} min"
fi

# Completa il comando ffmpeg con gli altri parametri necessari
FFMPEG_CMD+=" -ac 1 -ar 16000 -vn \"$AUDIO_FILE\" -y"

# Esegui il comando ffmpeg
eval $FFMPEG_CMD

echo "☁️ Controllo se l'audio è già presente su S3..."
AUDIO_UPLOADED=""
if ! aws s3 ls s3://$BUCKET_NAME/$AUDIO_FILE >/dev/null 2>&1; then
  echo "⬆️ Carico $AUDIO_FILE su S3..."
  aws s3 cp $AUDIO_FILE s3://$BUCKET_NAME/
  AUDIO_UPLOADED="true"
else
  echo "✅ Audio già presente su S3. Salto upload."
fi

# === CONTROLLA O CREA LA DEFAULT VPC ===
echo "🔍 Controllo default VPC nella regione $REGION..."
DEFAULT_VPC_ID=$(aws ec2 describe-vpcs --region $REGION --filters Name=isDefault,Values=true --query "Vpcs[0].VpcId" --output text)

if [ "$DEFAULT_VPC_ID" = "None" ]; then
  echo "➕ Nessuna default VPC trovata. La creo..."
  DEFAULT_VPC_ID=$(aws ec2 create-default-vpc --region $REGION --query "Vpc.VpcId" --output text)
  echo "✅ Default VPC creata: $DEFAULT_VPC_ID"
else
  echo "✅ Default VPC esistente: $DEFAULT_VPC_ID"
fi

# === CREA SECURITY GROUP SE NECESSARIO ===
aws ec2 describe-security-groups --group-names $SECURITY_GROUP --region $REGION &>/dev/null
if [ $? -ne 0 ]; then
  echo "➕ Creo security group $SECURITY_GROUP..."
  aws ec2 create-security-group --group-name $SECURITY_GROUP --description "Whisper SG" --vpc-id $DEFAULT_VPC_ID --region $REGION
  aws ec2 authorize-security-group-ingress --group-name $SECURITY_GROUP --protocol tcp --port 22 --cidr 0.0.0.0/0 --region $REGION
fi

# === AVVIA L'ISTANZA EC2 ===
echo "🚀 Avvio istanza EC2 GPU ($INSTANCE_TYPE con GPU)..."
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id $AMI_ID \
  --instance-type $INSTANCE_TYPE \
  --key-name $KEY_NAME \
  --security-groups $SECURITY_GROUP \
  --iam-instance-profile Name=WhisperS3Profile \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":50}}]' \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=whisper-runner}]" \
  --region $REGION \
  --query "Instances[0].InstanceId" \
  --output text)

if [ -z "$INSTANCE_ID" ]; then
  echo "❌ ERRORE: ID istanza non ottenuto. Verifica che l'AMI sia corretta per la regione $REGION."
  exit 1
fi

echo "🆔 Istanza avviata: $INSTANCE_ID"

# === FUNZIONE DI CLEANUP IN CASO DI USCITA IMPROVVISA ===
function cleanup {
  echo "🧨 Cleanup in corso..."

  # Rimuove il file audio locale se esiste
  if [ -f "$AUDIO_FILE" ]; then
    echo "🧹 Rimuovo file audio locale $AUDIO_FILE..."
    rm -f "$AUDIO_FILE"
    echo "✅ File audio locale rimosso."
  fi

  # Rimuove l'audio da S3 se è stato caricato in questo script
  if [ "$AUDIO_UPLOADED" = "true" ]; then
    echo "🧹 Rimuovo $AUDIO_FILE da S3..."
    aws s3 rm s3://$BUCKET_NAME/$AUDIO_FILE
    echo "✅ File rimosso da S3."
  fi

  # Termina l'istanza EC2 se è stata avviata
  if [ -n "$INSTANCE_ID" ]; then
    echo "🧹 Termino l'istanza EC2 ($INSTANCE_ID)..."
    aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region $REGION >/dev/null

    # Aspetta la terminazione con timeout
    echo "⏳ Aspetto la terminazione dell'istanza (max 60 secondi)..."
    WAIT_TIMEOUT=60
    WAIT_START=$(date +%s)

    WAITING=true
    while [ "$WAITING" = true ]; do
      # Controlla lo stato dell'istanza
      STATUS=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --region $REGION --query "Reservations[0].Instances[0].State.Name" --output text 2>/dev/null)

      # Se lo stato è terminated o l'istanza non esiste più, esci dal ciclo
      if [ "$STATUS" = "terminated" ] || [ "$STATUS" = "None" ]; then
        echo "✅ Istanza terminata con successo."
        WAITING=false
      else
        # Controlla se è scaduto il timeout
        WAIT_ELAPSED=$(($(date +%s) - WAIT_START))
        if [ $WAIT_ELAPSED -ge $WAIT_TIMEOUT ]; then
          echo "⚠️ Timeout durante l'attesa della terminazione. L'istanza potrebbe essere ancora in fase di terminazione."
          WAITING=false
        else
          # Aspetta un secondo prima di controllare di nuovo
          sleep 2
          echo -n "."
        fi
      fi
    done
  fi
}

# Esegui cleanup su qualsiasi uscita: normale, errore, o Ctrl+C
trap cleanup EXIT

echo "⏳ Attendo che sia pronta..."
aws ec2 wait instance-running --instance-ids $INSTANCE_ID --region $REGION

echo "🔐 Aspetto che l'istanza sia pronta per SSH..."
for i in {1..35}; do
  PUBLIC_IP=$(aws ec2 describe-instances --instance-id $INSTANCE_ID --region $REGION --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
  echo "🌍 IP pubblico: $PUBLIC_IP"

  nc -zv $PUBLIC_IP 22 >/dev/null 2>&1
  if [ $? -eq 0 ]; then
    echo "✅ Porta 22 aperta, l'istanza è pronta!"
    break
  else
    echo "⏳ Tentativo $i/35: porta 22 ancora chiusa. Riprovo tra 5s..."
    sleep 5
  fi
done

# === CARICA SCRIPT PYTHON SULL'ISTANZA ===
echo "📦 Carico script sulla macchina EC2..."
scp -o StrictHostKeyChecking=no -i $KEY_FILE parallel_transcript.py ubuntu@$PUBLIC_IP:/home/ubuntu/
scp -o StrictHostKeyChecking=no -i $KEY_FILE .env ubuntu@$PUBLIC_IP:/home/ubuntu/
scp -o StrictHostKeyChecking=no -i $KEY_FILE requirements.txt ubuntu@$PUBLIC_IP:/home/ubuntu/

echo "⚙️ Scarico audio da S3 ed eseguo trascrizione avanzata..."
ssh -t -i $KEY_FILE -o "SendEnv=TERM" ubuntu@$PUBLIC_IP "
  # Prevent broken pipe errors
  export PYTHONUNBUFFERED=1
  set -e
  cd /home/ubuntu

  echo '⬇️ Download da S3...'
  aws s3 cp s3://$BUCKET_NAME/$AUDIO_FILE /home/ubuntu/$AUDIO_FILE --region $REGION

  echo '📦 File scaricato:'
  ls -lh $AUDIO_FILE

  echo '⚙️ Attivo ambiente virtuale...'
  source whisper-env/bin/activate

  # Installa PyDub se non presente
  if ! pip list | grep -q pydub; then
    echo '📦 Installo dipendenze mancanti...'
    pip install pydub
  fi

  # Installa le dipendenze da requirements.txt
  pip install -r requirements.txt

  echo '🖥️ Informazioni GPU:'
  nvidia-smi

  echo 'Audio file: $AUDIO_FILE'
  echo 'Token Hugging Face: $HF_TOKEN'
  echo 'Diarization enabled: $DIARIZATION_ENABLED'
  echo 'Numero di speaker: $NUM_SPEAKERS'
  echo '✍️ Lancio trascrizione avanzata...'
  CMD=\"python3 parallel_transcript.py --audio $AUDIO_FILE --token $HF_TOKEN \
      --output-prefix $TRANSCRIPT_PREFIX\"

  if [ \"$DIARIZATION_ENABLED\" = false ]; then
    CMD+=\" --no-diarization\"
  fi

  if [ -n \"$NUM_SPEAKERS\" ]; then
    CMD+=\" --num-speakers $NUM_SPEAKERS\"
    echo '👥 Utilizzo numero di speaker specificato: $NUM_SPEAKERS'
  fi

  if [ \"$FIX_START\" = true ]; then
    CMD+=\" --fix-start\"
    echo '⏱️ Aggiunta correzione per i primi secondi'
  fi

  eval \$CMD
"

# === SCARICA I FILE ===
echo "⬇️ Scarico i file di output..."
scp -i $KEY_FILE ubuntu@$PUBLIC_IP:/home/ubuntu/${TRANSCRIPT_PREFIX}_final.txt . || echo "⚠️ Impossibile scaricare _final.txt (potrebbe non essere stato generato)"
scp -i $KEY_FILE ubuntu@$PUBLIC_IP:/home/ubuntu/${TRANSCRIPT_PREFIX}.txt . || echo "⚠️ Impossibile scaricare .txt"
scp -i $KEY_FILE ubuntu@$PUBLIC_IP:/home/ubuntu/${TRANSCRIPT_PREFIX}.srt . || echo "⚠️ Impossibile scaricare .srt"
scp -i $KEY_FILE ubuntu@$PUBLIC_IP:/home/ubuntu/${TRANSCRIPT_PREFIX}.vtt . || echo "⚠️ Impossibile scaricare .vtt"

# Scarica anche i file JSON con dati aggiuntivi per debugging
scp -i $KEY_FILE ubuntu@$PUBLIC_IP:/home/ubuntu/${TRANSCRIPT_PREFIX}.txt.words.json . 2>/dev/null || true
scp -i $KEY_FILE ubuntu@$PUBLIC_IP:/home/ubuntu/${TRANSCRIPT_PREFIX}_final.txt.diarization.json . 2>/dev/null || true
scp -i $KEY_FILE ubuntu@$PUBLIC_IP:/home/ubuntu/${TRANSCRIPT_PREFIX}_final.txt.overlaps.json . 2>/dev/null || true

echo "📄 File scaricati:"
ls -lh ${TRANSCRIPT_PREFIX}* 2>/dev/null || echo "⚠️ Nessun file trovato con il prefisso specificato"
