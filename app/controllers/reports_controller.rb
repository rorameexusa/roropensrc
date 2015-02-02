class ReportsController < ApplicationController
  layout "report_base"
  menu_item :issues
  before_filter :find_optional_project
  before_filter :load_available_criterias

  include SortHelper
  include TimelogHelper
  include CustomFieldsHelper

  def show
    @criterias = params[:criterias] || []
    @criterias = @criterias.select{|criteria| @available_criterias.has_key? criteria}
    @criterias.uniq!
    @criterias = @criterias[0,3]

    @columns = (params[:columns] && %w(year month week day).include?(params[:columns])) ? params[:columns] : 'month'

    retrieve_date_range

    unless @criterias.empty?
      sql_select = @criterias.collect{|criteria| @available_criterias[criteria][:sql] + " AS " + criteria}.join(', ')
      sql_group_by = @criterias.collect{|criteria| @available_criterias[criteria][:sql]}.join(', ')
      sql_condition = ''

      if @project.nil?
        sql_condition = Project.allowed_to_condition(User.current, :view_time_entries)
      elsif @issue.nil?
        sql_condition = @project.project_condition(Setting.display_subprojects_work_packages?)
      else
        sql_condition = "#{WorkPackage.table_name}.root_id = #{@issue.root_id} AND #{WorkPackage.table_name}.lft >= #{@issue.lft} AND #{WorkPackage.table_name}.rgt <= #{@issue.rgt}"
      end

      sql = "SELECT #{sql_select}, tyear, tmonth, tweek, spent_on, SUM(hours) AS hours"
      sql << " FROM #{TimeEntry.table_name}"
      sql << time_report_joins
      sql << " WHERE"
      sql << " (%s) AND" % sql_condition
      sql << " (spent_on BETWEEN '%s' AND '%s')" % [ActiveRecord::Base.connection.quoted_date(@from), ActiveRecord::Base.connection.quoted_date(@to)]
      sql << " GROUP BY #{sql_group_by}, tyear, tmonth, tweek, spent_on"

      @hours = ActiveRecord::Base.connection.select_all(sql)

      @hours.each do |row|
        case @columns
          when 'year'
            row['year'] = row['tyear']
          when 'month'
            row['month'] = "#{row['tyear']}-#{row['tmonth']}"
          when 'week'
            row['week'] = "#{row['tyear']}-#{row['tweek']}"
          when 'day'
            row['day'] = "#{row['spent_on']}"
        end
      end

      @total_hours = @hours.inject(0) {|s,k| s = s + k['hours'].to_f}

      @periods = []
      # Date#at_beginning_of_ not supported in Rails 1.2.x
      date_from = @from.to_time
      # 100 columns max
      while date_from <= @to.to_time && @periods.length < 100
        case @columns
          when 'year'
            @periods << "#{date_from.year}"
            date_from = (date_from + 1.year).at_beginning_of_year
          when 'month'
            @periods << "#{date_from.year}-#{date_from.month}"
            date_from = (date_from + 1.month).at_beginning_of_month
          when 'week'
            @periods << "#{date_from.year}-#{date_from.to_date.cweek}"
            date_from = (date_from + 7.day).at_beginning_of_week
          when 'day'
            @periods << "#{date_from.to_date}"
            date_from = date_from + 1.day
        end
      end
    end

    respond_to do |format|
      format.html { render :layout => !request.xhr? }
      format.csv  { send_data(spent_report_to_csv(@criterias, @periods, @hours), :type => 'text/csv; header=present', :filename => 'timelog.csv') }
    end
  end

def report_view
  @user = User.find_by_sql(%q{;with cte as(select s.value,x.id,s.custom_field_id,firstname||' ' ||lastname as Emp_Name from users x
left join custom_values s on s.customized_id=x.id
left join work_packages z on z.id=x.id
left join statuses A on A.id=z.status_id AND z.status_id not in (7,5,6,11,10) left join (
select distinct users.id FROM "work_packages"
LEFT OUTER JOIN "statuses" ON "statuses"."id" = "work_packages"."status_id"
LEFT OUTER JOIN "projects" ON "projects"."id" = "work_packages"."project_id"
LEFT OUTER JOIN "types" ON "types"."id" = "work_packages"."type_id"
LEFT OUTER JOIN "users" ON "users"."id" = "work_packages"."assigned_to_id"
LEFT OUTER JOIN "users" "responsibles_work_packages" ON "responsibles_work_packages"."id" = "work_packages"."responsible_id"
LEFT OUTER JOIN "work_packages" "parents_work_packages" ON "parents_work_packages"."id" = "work_packages"."parent_id"
WHERE (((work_packages.updated_at > (select now() - '2 day'::INTERVAL) AND work_packages.updated_at <= (select now()))
AND work_packages.status_id in (7,5,6,11,10)
AND projects.status=1 AND projects.id IN (SELECT em.project_id FROM enabled_modules em WHERE em.name='work_package_tracking')))
)y on x.id=y.id  where y.id is null and x.type not in ('Group','DeletedUser','AnonymousUser')
)
select distinct y.value as emp_id,cte1.emp_name as emp_name, z.value as report_manager, w.value as team
from cte cte1 left join cte y on cte1.id=y.id
and y.custom_field_id=28 left join cte z on z.id=cte1.id
and z.custom_field_id=27 left join cte w on w.id=cte1.id
and w.custom_field_id=29 order by emp_name})
  respond_to do |format|
    format.html { render :layout => !request.xhr? }
    format.csv  { send_data(report_view_csv(@user), :type => 'text/csv; header=present', :filename => 'report_view.csv') }
  end
end
def all_open_project_users
  @all_users = User.where("type not in ('Group','DeletedUser','AnonymousUser')").order("firstname asc")
  respond_to do |format|
    format.html { render :layout => !request.xhr? }
    format.csv  { send_data(all_open_project_users_csv(@all_users), :type => 'text/csv; header=present', :filename => 'all_open_project_users.csv') }
  end
end


  # for Admin task tracking from Date and that date time 11.30am and 08.30pm send mail
  def admin_tasks_due
    @status = Status.pluck(:name)
    @priority = Enumeration.where(type: 'IssuePriority').pluck(:name)

    @date = Time.now.strftime("%Y/%m/%d")

    admin_tasks_due = WorkPackage.where("type_id = ? and status_id != ? and date(due_date) <= ?",25,10,@date.to_date)
    @view_array = []

    admin_tasks_due.each do |workpackage|

      view_hash = {}

      view_hash[:task_no]             = workpackage.id
      view_hash[:workpackage_subject] = workpackage.subject
      view_hash[:prioriry]            = workpackage.priority.name
      view_hash[:status]              = workpackage.status.name

      user = User.where( id: workpackage.assigned_to_id, type: 'User' ).first if workpackage.assigned_to_id

      view_hash[:assignee]            = user.present? ? user.name : '---'

      author = User.find(workpackage.author_id).name if workpackage.author_id

      view_hash[:author]              = author.present? ? author : '---'
      view_hash[:start_date]          = workpackage.start_date
      view_hash[:due_date]            = workpackage.due_date.present? ? workpackage.due_date : '---'
      view_hash[:created_at]          = workpackage.created_at
      view_hash[:ets]                 = workpackage.estimated_hours.present? ? workpackage.estimated_hours : '---'

      @view_array << view_hash

    end
  end

  def admin_tasks_due_ajax_request


    @date = Time.now.strftime("%Y/%m/%d")
    admin_tasks_due = []
    if params[:status].present?
      status_id = Status.where(name: params[:status]).first!.id
      admin_tasks_due = WorkPackage.where("type_id = ? and status_id = ? and date(due_date) <= ?",25,status_id,@date.to_date)
    else
      priority_id = Enumeration.where(name: params[:priority]).first!.id
      admin_tasks_due = WorkPackage.where("type_id = ? and priority_id = ? and status_id != ? and date(due_date) <= ?",25,priority_id,10,@date.to_date)
    end


    view_array = []

    admin_tasks_due.each do |workpackage|

      view_hash = {}

      view_hash[:task_no]             = workpackage.id
      view_hash[:workpackage_subject] = workpackage.subject
      view_hash[:prioriry]            = workpackage.priority.name
      view_hash[:status]              = workpackage.status.name

      user = User.where( id: workpackage.assigned_to_id, type: 'User' ).first if workpackage.assigned_to_id

      view_hash[:assignee]            = user.present? ? user.name : '---'

      author = User.find(workpackage.author_id).name if workpackage.author_id

      view_hash[:author]              = author.present? ? author : '---'
      view_hash[:start_date]          = workpackage.start_date
      view_hash[:due_date]            = workpackage.due_date.present? ? workpackage.due_date : '---'
      view_hash[:created_at]          = workpackage.created_at
      view_hash[:ets]                 = workpackage.estimated_hours.present? ? workpackage.estimated_hours : '---'

      view_array << view_hash
    end

    render json: view_array.to_json and return
  end


  private

  def load_available_criterias
    @available_criterias = {
                             'member' => {:sql => "#{TimeEntry.table_name}.user_id",
                                          :klass => User,
                                          :label => "UserName,EmpID,RepMgr,Team"}
}

    # Add list and boolean custom fields as available criterias
    custom_fields = (@project.nil? ? WorkPackageCustomField.for_all : @project.all_work_package_custom_fields)
    custom_fields.select {|cf| %w(list bool).include? cf.field_format }.each do |cf|
      @available_criterias["cf_#{cf.id}"] = {:sql => "(SELECT c.value FROM #{CustomValue.table_name} c WHERE c.custom_field_id = #{cf.id} AND c.customized_type = 'WorkPackage' AND c.customized_id = #{WorkPackage.table_name}.id)",
                                             :format => cf.field_format,
                                             :label => cf.name}
    end if @project

    # Add list and boolean time entry custom fields
    TimeEntryCustomField.find(:all).select {|cf| %w(list bool).include? cf.field_format }.each do |cf|
      @available_criterias["cf_#{cf.id}"] = {:sql => "(SELECT c.value FROM #{CustomValue.table_name} c WHERE c.custom_field_id = #{cf.id} AND c.customized_type = 'TimeEntry' AND c.customized_id = #{TimeEntry.table_name}.id)",
                                             :format => cf.field_format,
                                             :label => cf.name}
    end

    # Add list and boolean time entry activity custom fields
    TimeEntryActivityCustomField.find(:all).select {|cf| %w(list bool).include? cf.field_format }.each do |cf|
      @available_criterias["cf_#{cf.id}"] = {:sql => "(SELECT c.value FROM #{CustomValue.table_name} c WHERE c.custom_field_id = #{cf.id} AND c.customized_type = 'Enumeration' AND c.customized_id = #{TimeEntry.table_name}.activity_id)",
                                             :format => cf.field_format,
                                             :label => cf.name}
    end

    call_hook(:controller_timelog_available_criterias, { :available_criterias => @available_criterias, :project => @project })
    @available_criterias
  end




  def time_report_joins
    sql = ''
    sql << " LEFT JOIN #{WorkPackage.table_name} ON #{TimeEntry.table_name}.work_package_id = #{WorkPackage.table_name}.id"
    sql << " LEFT JOIN #{Project.table_name} ON #{TimeEntry.table_name}.project_id = #{Project.table_name}.id"
    # TODO: rename hook
    call_hook(:controller_timelog_time_report_joins, {:sql => sql} )
    sql
  end

  def default_breadcrumb
    I18n.t(:label_spent_time)
  end
end
