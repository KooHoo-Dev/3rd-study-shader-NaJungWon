// =====================================================================
//  BlackHoleCommon.hlsl
//  블랙홀 셰이더 3종이 함께 쓰는 함수 모음.
//    - 01 GravityLens      : BH_ProjectCenter, BH_LensUV, BH_EventHorizon
//    - 02 AccretionFlow    : BH_VortexUV, BH_FlowNoise
//    - 03 DebrisDissolve   : BH_DissolveNoise, BH_LoopThreshold, BH_CollapseProgress, BH_CollapseVertex, BH_SwirlRotate
//  (볼 4 / 행성의 죽음은 새 셰이더 없이 위 3개의 머티리얼을 파트별로 나누거나 겹쳐서 만든다)
//  모든 메시(셰이더볼 파트, 구)는 피벗이 구의 중심에 있다고 본다.
//  Core.hlsl 을 먼저 include 한 뒤 include 해야 한다.
// =====================================================================
#ifndef MYSHADERS_BLACKHOLE_COMMON_INCLUDED
#define MYSHADERS_BLACKHOLE_COMMON_INCLUDED

// ---------------------------------------------------------------------
// [공통] 블랙홀 중심 = 오브젝트 원점(구의 중심)을 월드로 옮긴 위치
// ---------------------------------------------------------------------
float3 BH_CenterWS()
{
    return TransformObjectToWorld(float3(0, 0, 0));
}

// ---------------------------------------------------------------------
// [01 렌즈] 블랙홀 중심과 반지름을 화면 좌표로 옮긴다.
//   centerUV : 화면(0~1)에서 중심 위치
//   radiusUV : 월드 반지름이 화면 세로 기준으로 몇 UV 인지
// ---------------------------------------------------------------------
void BH_ProjectCenter(float3 centerWS, float radiusWS, out float2 centerUV, out float radiusUV)
{
    float4 centerCS = TransformWorldToHClip(centerWS);
    float4 sp = ComputeScreenPos(centerCS);
    centerUV = sp.xy / sp.w;
    // 투영행렬 _m11 = 1/tan(FOV/2). 화면 세로 절반 = UV 0.5
    radiusUV = 0.5 * radiusWS * abs(UNITY_MATRIX_P._m11) / max(centerCS.w, 1e-4);
}

// ---------------------------------------------------------------------
// [01 렌즈] 중력 렌즈 UV
//   얇은 렌즈 근사(아인슈타인 렌즈 방정식)  β = θ - θE² / θ
//   θ  : 지금 픽셀이 중심에서 떨어진 거리(rn, 볼 반지름=1 기준)
//   β  : 그 빛이 실제로 출발한 위치(rs)
//   rn = θE 인 곳에서 rs = 0 → 중심 뒤의 빛이 고리로 퍼져 보인다(아인슈타인 링)
//   rn < θE 인 곳은 rs 가 음수 → 반대편 상이 뒤집혀 보인다.
//   볼 가장자리(rn→1)에서는 굴절을 0으로 줄여 실루엣에 이음매가 생기지 않게 한다.
// ---------------------------------------------------------------------
float2 BH_LensUV(float2 screenUV, float2 centerUV, float radiusUV, float aspect,
                 float einstein, float falloffStart, out float rn)
{
    float2 d = screenUV - centerUV;
    d.x *= aspect;                               // 가로 UV 를 세로 UV 단위로 맞춘다(원이 찌그러지지 않게)
    float r = length(d);
    rn = r / max(radiusUV, 1e-5);
    float2 dir = d / max(r, 1e-5);

    float fade = 1.0 - smoothstep(falloffStart, 1.0, rn);
    float e = einstein * fade;
    float rs = rn - (e * e) / max(rn, 1e-3);
    rs = clamp(rs, -3.0, 3.0);

    float2 src = dir * rs * radiusUV;
    src.x /= aspect;
    return saturate(centerUV + src);
}

// ---------------------------------------------------------------------
// [01 렌즈] 사건의 지평선(검은 원) + 광자 고리
//   hole : 지평선 안쪽 0, 바깥 1 (SDF 원 + smoothstep)
//   ring : 지평선 바로 바깥(반지름 ×1.07)의 얇은 빛 띠(가우시안)
// ---------------------------------------------------------------------
void BH_EventHorizon(float rn, float horizon, out float hole, out float ring)
{
    hole = smoothstep(horizon - 0.015, horizon + 0.015, rn);
    float x = (rn - horizon * 1.07) / 0.025;
    ring = exp(-x * x);
}

// ---------------------------------------------------------------------
// [02 플로] 소용돌이 좌표
//   "중심 → 카메라" 축에 수직인 평면에 표면 위치를 투영해 0~1 UV 를 만든다.
//   어느 각도에서 봐도 소용돌이의 눈이 관찰자를 향한다.
// ---------------------------------------------------------------------
float2 BH_VortexUV(float3 positionWS, float3 centerWS, float radiusWS)
{
    float3 axis  = normalize(_WorldSpaceCameraPos - centerWS);
    float3 right = normalize(cross(float3(0, 1, 0), axis));
    float3 up    = cross(axis, right);
    float3 p = positionWS - centerWS;
    return float2(dot(p, right), dot(p, up)) / max(radiusWS, 1e-4) * 0.5 + 0.5;
}

// ---------------------------------------------------------------------
// [01 렌즈] 렌즈로 휜 화면 색 읽기 + 앞 물체 검사 (갤러리 '씬 컬러 굴절 유리')
//   Opaque Texture 는 렌즈 앞/뒤를 가리지 않으므로, 밀린 좌표가 렌즈보다 앞에 있는
//   물체(예: 볼의 링)를 가리키면 그 물체가 렌즈 속으로 끌려 들어와 보인다.
//   밀린 좌표의 씬 깊이가 이 픽셀보다 앞이면 밀지 않은 좌표로 돌아간다.
//   사용하는 셰이더에서 DeclareOpaqueTexture / DeclareDepthTexture 를 먼저 include 하고
//   BH_LENS_SAMPLING 을 define 한다.
// ---------------------------------------------------------------------
#if defined(BH_LENS_SAMPLING)
float BH_SceneEyeDepth(float2 uv)
{
    return LinearEyeDepth(SampleSceneDepth(uv), _ZBufferParams);
}

float2 BH_FrontObjectCheck(float2 shiftedUV, float2 screenUV, float selfEye)
{
    return (BH_SceneEyeDepth(shiftedUV) < selfEye) ? screenUV : shiftedUV;
}

float3 BH_SampleLensed(float2 uvR, float2 uvG, float2 uvB, float2 screenUV, float selfEye)
{
    float3 col;
    col.r = SampleSceneColor(BH_FrontObjectCheck(uvR, screenUV, selfEye)).r;
    col.g = SampleSceneColor(BH_FrontObjectCheck(uvG, screenUV, selfEye)).g;
    col.b = SampleSceneColor(BH_FrontObjectCheck(uvB, screenUV, selfEye)).b;
    return col;
}
#endif

// ---------------------------------------------------------------------
// [02 플로] 플로 맵 + 두 위상 섞기 (갤러리 '플로 맵 액체')
//   플로 맵 RG = 흐름 방향(0~1 로 저장 → -1~1 로 복원), B = 위상 노이즈.
//   위상 하나만 쓰면 늘어난 무늬가 주기마다 원래 모양으로 '툭' 튀므로
//   반 주기 어긋난 두 층을 삼각파 가중치로 섞어 튀는 순간을 숨긴다.
//   위상 노이즈는 자리마다 튀는 시점을 흩어 표면 전체가 동시에 튀지 않게 한다.
// ---------------------------------------------------------------------
float BH_FlowWeight(float phase)
{
    return 1.0 - abs(1.0 - 2.0 * phase);         // 위상 0,1 → 0 / 위상 0.5 → 1
}

float BH_FlowNoise(TEXTURE2D_PARAM(flowTex, flowSampler), TEXTURE2D_PARAM(patternTex, patternSampler),
                   float2 uv, float flowStrength, float speed, float patternScale, float phaseNoise, float time)
{
    float3 flowTexel = SAMPLE_TEXTURE2D(flowTex, flowSampler, uv).rgb;
    float2 flow = (flowTexel.xy * 2.0 - 1.0) * flowStrength;

    float t = time * speed;
    float n = flowTexel.z * phaseNoise;
    float phaseA = frac(t + n);
    float phaseB = frac(t + n + 0.5);

    float patA = SAMPLE_TEXTURE2D(patternTex, patternSampler, (uv - flow * phaseA) * patternScale).r;
    float patB = SAMPLE_TEXTURE2D(patternTex, patternSampler, (uv - flow * phaseB) * patternScale).r;
    float wA = BH_FlowWeight(phaseA);
    return patA * wA + patB * (1.0 - wA);
}

// ---------------------------------------------------------------------
// [03 디졸브] 3D 값 노이즈 (갤러리 '디졸브' 와 같은 방식)
//   UV 대신 오브젝트 공간 위치를 쓰므로 파트마다 UV 이음매가 있어도 끊기지 않는다.
//   정점 셰이더에서도 같은 값을 계산할 수 있어 '빨려 드는 변형'과 '잘라 내기'가 정확히 맞는다.
// ---------------------------------------------------------------------
float BH_Hash(float3 p)
{
    p = frac(p * 0.1031);
    p = p + dot(p, p.zyx + 31.32);
    return frac((p.x + p.y) * p.z);
}

float BH_ValueNoise(float3 p)
{
    float3 cell = floor(p);
    float3 f = frac(p);
    f = f * f * (3.0 - 2.0 * f);
    float x00 = lerp(BH_Hash(cell + float3(0, 0, 0)), BH_Hash(cell + float3(1, 0, 0)), f.x);
    float x10 = lerp(BH_Hash(cell + float3(0, 1, 0)), BH_Hash(cell + float3(1, 1, 0)), f.x);
    float x01 = lerp(BH_Hash(cell + float3(0, 0, 1)), BH_Hash(cell + float3(1, 0, 1)), f.x);
    float x11 = lerp(BH_Hash(cell + float3(0, 1, 1)), BH_Hash(cell + float3(1, 1, 1)), f.x);
    return lerp(lerp(x00, x10, f.y), lerp(x01, x11, f.y), f.z);
}

float BH_DissolveNoise(float3 p)
{
    float n = BH_ValueNoise(p) * 0.6;
    n += BH_ValueNoise(p * 2.03 + float3(11.7, 3.1, 7.9)) * 0.28;
    n += BH_ValueNoise(p * 4.01 + float3(5.3, 17.2, 2.4)) * 0.12;
    return saturate((n - 0.2) / 0.6);
}

// ---------------------------------------------------------------------
// [03 디졸브] 임계값 (갤러리 '디졸브' 의 _Threshold)
//   원본은 C# 에서 _Threshold 를 올려 연출한다.
//   여기서는 autoPlay 를 켜면 셰이더 안에서 frac(time * speed) 로 0 → 1 을 반복한다.
//   이 값을 한 바퀴의 진행 시간(life)으로 쓴다.
//     [0, formDuration]  : 생성 — 디졸브를 거꾸로(임계값 1 → 0) 돌려 나타난다
//     [.., pullStart]    : 유지 — 온전한 표면
//     [pullStart, 1]     : 흡입 — 덩어리마다 시차를 두고 중심으로 빨려 들며 사라진다
// ---------------------------------------------------------------------
float BH_LoopThreshold(float manual, float autoPlay, float speed, float time)
{
    return lerp(manual, frac(time * speed), autoPlay);
}

// 생성 구간의 잘라 내기 기준: life 0 에서 1(전부 잘림) → formDuration 에서 0(전부 보임)
float BH_FormCut(float life, float formDuration)
{
    return saturate(1.0 - life / max(formDuration, 1e-4));
}

// 덩어리별 흡입 진행도(0~1)
//   덩어리마다 출발 시점(delay 0~1)을 다르게 해서 한 덩어리씩 떨어져 나가게 한다.
//   가장 늦은 덩어리도 life = 1 에서 끝나므로 다음 바퀴로 넘어갈 때 남는 조각이 없다.
float BH_CollapseProgress(float life, float pullStart, float pullDuration, float delay)
{
    pullDuration = clamp(pullDuration, 0.01, 1.0 - pullStart);
    float start = pullStart + delay * (1.0 - pullStart - pullDuration);
    return saturate((life - start) / pullDuration);
}

// ---------------------------------------------------------------------
// [03 디졸브] 흡입 정점 변형 (갤러리 '정점 변형')
//   중심까지의 거리를 (1 - progress^accel) 배로 줄인다.
//   accel 이 크면 처음엔 표면에 머물다가 중심 근처에서 확 끌려간다.
//   출발 시점이 다른 덩어리 경계는 중심 방향으로 길게 늘어난다(스파게티화).
// ---------------------------------------------------------------------
float3 BH_CollapseVertex(float3 positionWS, float3 centerWS, float progress, float accel)
{
    float e = pow(saturate(progress), accel);
    return centerWS + (positionWS - centerWS) * (1.0 - e);
}

// ---------------------------------------------------------------------
// [03 디졸브] 흡입 회전 — 중심을 지나는 축(axis)으로 v 를 angle 만큼 돌린다 (로드리게스 회전)
//   중심으로 끌려가는 양과 같은 곡선(progress^accel)으로 각도를 늘리면
//   떨어질수록 빨리 돌며 나선을 그리고 빨려 든다. 법선도 같은 함수로 돌린다.
// ---------------------------------------------------------------------
float3 BH_SwirlRotate(float3 v, float3 axis, float angle)
{
    float s, c;
    sincos(angle, s, c);
    return v * c + cross(axis, v) * s + axis * dot(axis, v) * (1.0 - c);
}

#endif
