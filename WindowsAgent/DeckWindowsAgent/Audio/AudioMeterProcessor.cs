namespace DeckWindowsAgent.Audio;

public sealed class AudioMeterProcessor(
    float minimumDecibels = -60,
    float clippingDecibels = -0.5f,
    float attack = 0.65f,
    float decay = 0.12f,
    TimeSpan? peakHoldDuration = null)
{
    private readonly TimeSpan _peakHoldDuration = peakHoldDuration ?? TimeSpan.FromMilliseconds(750);
    private float _displayLevel;
    private float _peakHold;
    private long _peakHoldUntilMilliseconds;

    public ProcessedAudioMeter Process(float linearPeak, long timestampMilliseconds)
    {
        linearPeak = Math.Clamp(linearPeak, 0, 1);
        var decibels = LinearToDecibels(linearPeak, minimumDecibels);
        var normalized = NormalizeDisplayLevel(decibels, minimumDecibels);
        var coefficient = normalized >= _displayLevel ? attack : decay;
        _displayLevel += (normalized - _displayLevel) * coefficient;

        if (_displayLevel >= _peakHold)
        {
            _peakHold = _displayLevel;
            _peakHoldUntilMilliseconds = timestampMilliseconds + (long)_peakHoldDuration.TotalMilliseconds;
        }
        else if (timestampMilliseconds >= _peakHoldUntilMilliseconds)
        {
            _peakHold = Math.Max(_displayLevel, _peakHold - 0.08f);
        }

        return new ProcessedAudioMeter(
            linearPeak,
            decibels,
            Math.Clamp(_displayLevel, 0, 1),
            Math.Clamp(_peakHold, 0, 1),
            decibels >= clippingDecibels);
    }

    public void Reset()
    {
        _displayLevel = 0;
        _peakHold = 0;
        _peakHoldUntilMilliseconds = 0;
    }

    public static float LinearToDecibels(float linearPeak, float minimumDecibels = -60)
    {
        var decibels = 20f * MathF.Log10(MathF.Max(linearPeak, 0.000001f));
        return Math.Clamp(decibels, minimumDecibels, 0);
    }

    public static float NormalizeDisplayLevel(float decibels, float minimumDecibels = -60) =>
        Math.Clamp((decibels - minimumDecibels) / -minimumDecibels, 0, 1);
}

public readonly record struct ProcessedAudioMeter(
    float LinearPeak,
    float Decibels,
    float DisplayLevel,
    float PeakHold,
    bool IsClipping);
