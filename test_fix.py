import json

def split_long_segments(segments, max_chars=150):
    """Split segments that are too long into smaller chunks."""
    import re

    new_segments = []
    for segment in segments:
        if "text" in segment and len(segment["text"]) > max_chars:
            # Split text at sentence boundaries or by character count
            sentences = re.split(r'(?<=[.!?]) +', segment["text"])
            current_text = ""
            start_time = segment["start"]

            for sentence in sentences:
                if len(current_text) + len(sentence) > max_chars and current_text:
                    # Calculate proportional time based on text length
                    portion = len(current_text) / len(segment["text"])
                    mid_time = segment["start"] + portion * (segment["end"] - segment["start"])

                    new_segments.append({
                        "start": start_time,
                        "end": mid_time,
                        "text": current_text.strip(),
                        "speaker": segment.get("speaker", ""),
                        "speaker_text": segment.get("speaker_text", f"[{segment.get('speaker', '')}] ")  # Fixed line
                    })

                    start_time = mid_time
                    current_text = sentence
                else:
                    current_text += " " + sentence if current_text else sentence

            # Add the last part
            if current_text:
                new_segments.append({
                    "start": start_time,
                    "end": segment["end"],
                    "text": current_text.strip(),
                    "speaker": segment.get("speaker", ""),
                    "speaker_text": segment.get("speaker_text", f"[{segment.get('speaker', '')}] ")  # Fixed line
                })
        else:
            new_segments.append(segment)

    return new_segments

# Create mock test data
test_segments = [
    {
        "start": 0.0,
        "end": 10.0,
        "speaker": "SPEAKER_00",
        "speaker_text": "[SPEAKER_00] ",
        "text": "This is a very long text that exceeds the maximum character limit. It should be split into multiple segments. This is another sentence to make sure we have enough text to split. And one more sentence to be really sure."
    }
]

# Run the split_long_segments function
print("Testing split_long_segments...")
split_segments = split_long_segments(test_segments, max_chars=50)
print(f"Number of segments after splitting: {len(split_segments)}")

# Verify that all segments have the speaker_text field
all_have_speaker_text = all("speaker_text" in segment for segment in split_segments)
print(f"All segments have speaker_text field: {all_have_speaker_text}")

# Dump the result to inspect
print("\nSplit segments:")
print(json.dumps(split_segments, indent=2))

# Check if we can access speaker_text without error
try:
    for segment in split_segments:
        speaker_text = segment["speaker_text"]
    print("\n✅ Successfully accessed speaker_text on all segments")
except KeyError as e:
    print(f"\n❌ KeyError when accessing: {e}")
