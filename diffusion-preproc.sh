#! /bin/bash
set -e 

### Inputs
# AP_BASENAME="/RAID1/jupytertmp/diffusion-preproc/230622-Laura/dwi/sub-s230622_dir-AP_dwi"
# PA_BASENAME="/RAID1/jupytertmp/diffusion-preproc/230622-Laura/dwi/sub-s230622_dir-PA_dwi"
# OUT="/RAID1/jupytertmp/diffusion-preproc/230622-Laura/dwi-preproc"
SRC=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

usage() {
    cat <<EOF
    Usage: $(basename $0) [-i input directory with dicom files] [-o output directory]
EOF
}

while getopts a:p:o:n opt; do 
    case "$opt" in 
        a)
        AP_BASENAME=$OPTARG;;
        p)
        PA_BASENAME=$OPTARG;;
        o) 
        OUT=$OPTARG;;
        n)
        NTHR=$OPTARG;;
        h)
        usage && exit 0;;

        :)
        echo "Option requires an argument" >&2 && exit 1
        ;;

        /? | *)
        echo "Confusing stuff..." >&2 && exit 1
        ;;
    esac
done
shift "$(( OPTIND - 1 ))"

echo
echo "================ PREPROCESSING... ================"
echo
NTHR=20

echo AP_BASENAME: $AP_BASENAME
echo PA_BASENAME: $PA_BASENAME
echo OUT:         $OUT
echo NTHR:        $NTHR


### File checks
# Check that the output dir is not there
# [ -d $OUT ] && echo "$OUT already exists!" && exit 1

# Check if all files are there
basenames=( $AP_BASENAME $PA_BASENAME )
exts=( ".nii.gz" ".bvec" ".bval" ".json" )
for basename in ${basenames[@]}; do
    for ext in ${exts[@]}; do 
        file="${basename}${ext}"
        [ ! -f $file ] && echo "$file does not exist!" && exit 1
    done
done

start_time=$(date)
# mkdir $OUT && chmod 777 $OUT

### Check if the scans parameters match
echo
echo "================ checking files... ================"
echo

python $SRC/compare-paap.py -a $AP_BASENAME -p $PA_BASENAME

echo
echo start preprocessing?
select answer in Yes No; do
    case $answer in 
        Yes) 
            echo "let's go!" && break;;
        No) 
            exit 1;;
    esac
done
echo


### Adjust the small difference between the affines 
echo
echo "================ adjusting affines... ================"
echo

python $SRC/fix-affine-inaccuracy.py -a $AP_BASENAME -p $PA_BASENAME


### Concatenate the two phase-encoding directions  
echo
echo "================ preparing files... ================"
echo

bvals="${OUT}/bvals"
paste -d " " "${AP_BASENAME}.bval" "${PA_BASENAME}".bval > $bvals

# Tweak the bvals
bvals_rounded="${OUT}/bvals_rounded"
cp $bvals $bvals_rounded
sed -i -e "s/2050/2000/g" -e "s/1950/2000/g" -e "s/1050/1000/g" -e "s/950/1000/g" -e "s/50/0/g" $bvals_rounded

bvecs="${OUT}/bvecs"
paste -d " " "${AP_BASENAME}.bvec" "${PA_BASENAME}".bvec > $bvecs

dwi="${OUT}/dwi.nii.gz"
fslmerge -t $dwi "${AP_BASENAME}" "${PA_BASENAME}"


### Preprocess the dwi image
echo
echo "================ preprocessing dwi... ================"
echo

dwi_den="${OUT}/dwi_den.nii.gz"
dwidenoise $dwi $dwi_den -nthreads $NTHR

dwi_den_unr="${OUT}/dwi_den_unr.nii.gz"
mrdegibbs $dwi_den $dwi_den_unr -nthreads $NTHR -axes 1,0


### Topup - takes 1h30 with 20 threads
echo
echo "================ running topup... ================"
echo

topup_dir="${OUT}/topup"
mkdir $topup_dir

b0="${topup_dir}/b0.nii.gz"
dwiextract $dwi_den_unr $b0 -bzero -fslgrad $bvecs $bvals_rounded

# Make acqparams file 
acqparams="${topup_dir}/acqparams.txt"
touch $acqparams
basenames=( $AP_BASENAME $PA_BASENAME )
for basename in "${basenames[@]}"; do
    
    readout_time=$( jq .TotalReadoutTime "${basename}.json" ) #0.16236 # 0.028
    pe_dir=$( jq .PhaseEncodingDirection "${basename}.json" )
    if [[ $pe_dir == "\"j\"" ]]; then pe_dir=1; else pe_dir=-1; fi

    for b in $( cat "${basename}.bval" ); do
        if [ $b -le 100 ]; then
            echo "0 ${pe_dir} 0 ${readout_time}" >> $acqparams 
        fi
    done
done

echo "generated acqparams file:"
cat $acqparams
echo

topup_basename="${topup_dir}/b0_topup"
topup_img="${topup_dir}/b0_topup_img.nii.gz"
topup_field="${topup_dir}/b0_topup_field.nii.gz"
time topup \
    --imain=$b0 \
    --datain=$acqparams \
    --config=b02b0.cnf \
    --out=$topup_basename \
    --iout=$topup_img \
    --fout=$topup_field \
    --logout="${topup_dir}/topup.log" \
    --nthr=$NTHR \
    --scale=1 \
    --verbose


### Make binary brain mask
echo
echo "================ making brain mask... ================"
echo

b0_topup_img_mean="${topup_dir}/b0_topup_img_mean.nii.gz"
fslmaths $topup_img -Tmean $b0_topup_img_mean

b0_topup_img_mean_bcor="${topup_dir}/b0_topup_img_mean_bcor.nii.gz"
N4BiasFieldCorrection -d 3 -i $b0_topup_img_mean -o $b0_topup_img_mean_bcor -v

brainmask="${topup_dir}/b0_topup_img_mean_bcor_brainmask.nii.gz"
mri_synthstrip -i $b0_topup_img_mean_bcor -m $brainmask


### Run eddy current correction - takes ~3 hours on GPU
echo
echo "================ running eddy... ================"
echo

eddy_dir="${OUT}/eddy"
mkdir $eddy_dir

# Create index file 
index="${eddy_dir}/index.txt"
touch $index
i=0
for b in $(cat $bvals); do
    if [ $b = 0 ]; then i=$(( $i+1 )); fi;
    echo $i >> $index; 
done

# Create slice order file
slices="${eddy_dir}/slice-order.txt"
python $SRC/mb-slice-order.py -s "${AP_BASENAME}.json" -o $slices

eddy_basename="${eddy_dir}/eddy"
time eddy_cuda10.2 \
    --imain=$dwi_den_unr \
    --mask=$brainmask \
    --index=$index \
    --acqp=$acqparams \
    --topup=$topup_basename \
    --bvecs=$bvecs \
    --bvals=$bvals \
    --out=$eddy_basename \
    --flm=quadratic \
    --interp=spline \
    --resamp=lsr \ # jac
    --lsr_lambda=0.1 \
    --nvoxhp=10000 \
    --ff=10 \
    --repol \
    --ol_type=both \
    --mporder=6 \
    --s2v_niter=10 \
    --s2v_lambda=1 \
    --s2v_interp=trilinear \
    --slspec=$slices \
    --nthr=$NTHR \
    --estimate_move_by_susceptibility \
    --data_is_shelled \
    --cnr_maps \
    --very_verbose
#     --json="${AP_BASENAME}.json" \

# Average bvals and bvecs
# python $SRC/average_bvecs.py -b $bvals -v $bvecs_rot -o "${eddy_dir}/average"

bvecs_lsr="${eddy_basename}.eddy_rotated_bvecs_for_SLR"
bvals_lsr="${AP_BASENAME}.bval" # only from the first part 


### Eddy quality check
echo
echo "================ Running eddy qc... ================"
echo

qc_dir="${OUT}/eddyqc"
eddy_quad \
    $eddy_basename \
    --eddyIdx=$index \
    --eddyParams=$acqparams \
    --mask=$brainmask \
    --bvals=$bvals_lsr \
    --field=$topup_field \
    --slspec=$slices \
    --output=$qc_dir \


## Fit the diffusion tensor 
echo
echo "================ Running dti... ================"
echo

dti_dir="${OUT}/dti"
mkdir $dti_dir

dti_basename="${dti_dir}/dti"
dwi_preproc="${eddy_basename}.nii.gz"
time dtifit \
    --data=$dwi_preproc \
    --mask=$brainmask \
    --bvecs=$bvecs_lsr \
    --bvals=$bvals_lsr \
    --out=$dti_basename \
    --save_tensor \
    --verbose

# make a nice colour image for itksnap
tensor="${dti_basename}_tensor.nii.gz"
tensor_colour="${tensor%.nii.gz}_colour.nii.gz"
ImageMath 3 $tensor_colour 4DTensorTo3DTensor $tensor
Imagemath 3 $tensor_colour TensorColor $tensor_colour

echo -e "\n\nDONE"
echo "==================================="
echo "Started: $start_time"
echo "Finished: $(date)"
