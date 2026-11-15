// =====================================================================
//  01 GravityLens — 중력 렌즈 (바탕: 갤러리 '씬 컬러 굴절 유리')
//  불투명 물체가 다 그려진 화면(_CameraOpaqueTexture)을
//  아인슈타인 렌즈 방정식으로 휘어서 다시 그린다.
//  + 사건의 지평선(검은 원) + 광자 고리 + 색수차 + 프레넬 림
// =====================================================================
Shader "MyShaders/GravityLens"
{
    Properties
    {
        [Header(Lens)]
        _LensRadius   ("Lens Radius (world)", Float) = 0.55
        _Einstein     ("Einstein Radius (0-1)", Range(0, 1)) = 0.5
        _FalloffStart ("Edge Falloff Start (0-1)", Range(0, 1)) = 0.55
        _Chroma       ("Chromatic Aberration", Range(0, 0.5)) = 0.06

        [Header(Event Horizon)]
        _Horizon         ("Horizon Radius (0-1)", Range(0, 1)) = 0.3
        [HDR] _RingColor ("Photon Ring Color", Color) = (1.4, 1.0, 0.6, 1)

        [Header(Fresnel Rim)]
        [HDR] _RimColor ("Rim Color", Color) = (0.25, 0.4, 0.8, 1)
        _RimPower       ("Rim Power", Range(0.5, 8)) = 4
    }

    SubShader
    {
        // 불투명 패스가 끝난 뒤(= Opaque Texture 가 준비된 뒤) 그려야 하므로 Transparent 큐
        Tags { "RenderType" = "Transparent" "Queue" = "Transparent" "RenderPipeline" = "UniversalPipeline" }

        Pass
        {
            Name "ForwardUnlit"
            Tags { "LightMode" = "UniversalForward" }
            Blend Off        // 뒤 화면을 직접 샘플링해 색을 통째로 결정하므로 혼합이 필요 없다
            ZWrite On        // 갤러리 원본은 Off. 볼 파트끼리 겹칠 때 뒤 파트가 앞에 얹히지 않도록 On
            Cull Back

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareOpaqueTexture.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"
            #define BH_LENS_SAMPLING
            #include "../Shared/BlackHoleCommon.hlsl"

            CBUFFER_START(UnityPerMaterial)
                float  _LensRadius;
                float  _Einstein;
                float  _FalloffStart;
                float  _Chroma;
                float  _Horizon;
                float4 _RingColor;
                float4 _RimColor;
                float  _RimPower;
            CBUFFER_END

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS   : NORMAL;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float4 screenPos  : TEXCOORD0;
                float3 positionWS : TEXCOORD1;
                float3 normalWS   : TEXCOORD2;
            };

            Varyings vert(Attributes v)
            {
                Varyings o;
                VertexPositionInputs pos = GetVertexPositionInputs(v.positionOS.xyz);
                o.positionCS = pos.positionCS;
                o.positionWS = pos.positionWS;
                o.screenPos  = ComputeScreenPos(pos.positionCS);
                o.normalWS   = TransformObjectToWorldNormal(v.normalOS);
                return o;
            }

            float4 frag(Varyings i) : SV_Target
            {
                float2 screenUV = i.screenPos.xy / i.screenPos.w;

                // 1) 블랙홀 중심/반지름을 화면 좌표로
                float3 centerWS = BH_CenterWS();
                float2 centerUV; float radiusUV;
                BH_ProjectCenter(centerWS, _LensRadius, centerUV, radiusUV);
                float aspect = _ScreenParams.x / _ScreenParams.y;

                // 2) 렌즈 굴절 — 색수차: R/G/B 채널마다 아인슈타인 반지름을 살짝 다르게
                float rn;
                float2 uvR = BH_LensUV(screenUV, centerUV, radiusUV, aspect, _Einstein * (1.0 + _Chroma), _FalloffStart, rn);
                float2 uvB = BH_LensUV(screenUV, centerUV, radiusUV, aspect, _Einstein * (1.0 - _Chroma), _FalloffStart, rn);
                float2 uvG = BH_LensUV(screenUV, centerUV, radiusUV, aspect, _Einstein, _FalloffStart, rn);

                // 밀린 좌표가 렌즈 앞 물체를 가리키면 밀지 않은 좌표로 (갤러리의 앞 물체 검사)
                float selfEye = LinearEyeDepth(i.positionWS, UNITY_MATRIX_V);
                float3 col = BH_SampleLensed(uvR, uvG, uvB, screenUV, selfEye);

                // 3) 사건의 지평선 + 광자 고리
                float hole, ring;
                BH_EventHorizon(rn, _Horizon, hole, ring);
                col = col * hole + _RingColor.rgb * ring;

                // 4) 프레넬 림 — 구의 윤곽을 살짝 밝혀 '유리 구슬' 경계를 보여 준다
                float3 n = normalize(i.normalWS);
                float3 v = normalize(GetWorldSpaceViewDir(i.positionWS));
                float fres = pow(1.0 - saturate(dot(n, v)), _RimPower);
                col += _RimColor.rgb * fres;

                return float4(col, 1.0);
            }
            ENDHLSL
        }
    }
    FallBack Off
}
